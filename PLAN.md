# zuklear — porting plan

An **idiomatic** Zig 0.16.0 port of [Nuklear](https://github.com/Immediate-Mode-UI/Nuklear)
v4.13.3 (single-header immediate-mode GUI in C89). Not a `@cImport` wrapper — the
public API is redesigned to feel native to Zig.

## Source of truth

Port from the **modular** sources in `../src/*.c` and `../src/nuklear.h` (the public
header), *not* from the generated `../nuklear.h` amalgamation. The amalgamation is
produced from those files by `../src/build.py`.

Module sizes (LOC, the porting workload):

```
core/util    nuklear_math 355  color 423  utf8 144  string 448  util 1127
memory       buffer 276  pool 66  page_element 62
io/draw      input 423  draw 557  command (in draw/internal)  vertex 1340
context      context 344  style 873  panel 620  window 680  layout 768  group 251
widgets      widget 343  text 299  button 756  toggle 439  selectable 332
             slider 258  progress 158  scrollbar 310  property 542  knob 252
             edit 836  text_editor 1035  combo 855  contextual 226  menu 297
             tooltip 221  tree 351  chart 335  popup 263  table 88  list_view 86
             color_picker 201  image 139  9slice 106
font         font 1372  + vendored stb_rect_pack.h / stb_truetype.h (~5 kLOC C)
```

## Licensing (verified compatible)

- **Nuklear**: dual **MIT / Public Domain (Unlicense)**.
- **wio**: **MIT** (Elaine Gibson et al.).
- **stb_truetype.h / stb_rect_pack.h**: **MIT / Public Domain**.

zuklear ships under the same dual **MIT / Unlicense** as Nuklear (see `LICENSE`).
Third-party credits tracked in `THIRD-PARTY-NOTICES.md` as deps are integrated.

## Idiomatic mapping conventions

| Nuklear (C)                              | zuklear (Zig)                                            |
|------------------------------------------|---------------------------------------------------------|
| `nk_` prefix                             | dropped; namespaced (`zk.Context`, `ctx.buttonLabel()`) |
| `struct nk_context` + free functions     | `Context` struct with methods                           |
| `nk_vec2`, `nk_rect`, `nk_color`         | `Vec2`, `Rect`, `Color` (fields snake_case)             |
| `snake_case` funcs                       | `camelCase` methods/fns, `TitleCase` types              |
| `nk_allocator` callbacks                 | `std.mem.Allocator`                                     |
| `nk_buffer` / `nk_pool`                  | `std.ArrayList` / allocator-backed pools                |
| return codes / `nk_bool`                 | `bool` for predicates, `!T` error unions for fallible   |
| bitflag enums (`nk_window_flags`, …)     | `packed struct { … : bool }` flag sets                  |
| `nk_command` base + type tag + casts     | `Command` = `union(enum)`                               |
| `nk_handle` (id/ptr union)               | `Handle = union(enum) { id: i32, ptr: *anyopaque }`     |
| `NK_*_NEEDED` compile macros             | always-present Zig fns (dead-code-eliminated)           |

## Phases (headless core first; verify `zig build test` green before advancing)

**Phase 0 — Scaffold** ✅ in progress
Real `build.zig` (library module + tests + examples step), `root.zig` aggregator,
`LICENSE` (dual), `README.md`, `THIRD-PARTY-NOTICES.md`, this plan.

**Phase 1 — Foundations (headless, pure)** ✅ done
`math.zig` ✅ (uses std.math, not Nuklear's bundled approximations) →
`color.zig` ✅ (Color/Colorf, hex/hsv) → `utf8.zig` ✅ (decode/encode) →
`String.zig` ✅ (dynamic UTF-8 string) → `Buffer.zig` ✅ (double-ended buffer).
Each with `test` blocks.

Sequencing refinements made during the port:
- `pool`/`page_element` moved to **Phase 3**: they allocate the
  `nk_page_element` union (window/panel/table), so they need the context types.
- `util.zig` is ported **on demand**, not wholesale: most of `nuklear_util.c`
  (memcpy/memset/strlen/dtoa/ftoa/strtof…) is covered by Zig's `std`. Only
  helpers without a std equivalent get ported, when a consumer needs them.

**Phase 2 — Command buffer, draw, input** ✅ done
`command.zig` ✅ (`Command` union + `CommandBuffer` with every draw primitive —
shapes, text, image, nine-slice, custom; points/text are owned slices freed on
reset), `input.zig` ✅ (self-contained `Input` with feed + query methods).
Also landed the foundational `handle.zig` (`Handle`), `image.zig`
(`Image`/`NineSlice`) and `font.zig` (`UserFont` interface + `textClamp`),
which the draw layer depends on.

**Phase 3 — Context, style, window, panel, layout** 🚧 core landed
`style.zig` ✅, `hash.zig` ✅, `context.zig` ✅ (window + panel + layout in one
module: persistent windows with z-order list + name map + seq GC; begin/end;
panel begin/end with header background+title, window background, border, clip;
the row-layout engine `layoutRow*` + `widget` bounds allocation with the full
row-type switch). Smoke-tested begin/layout/widget/end + window reuse/GC.
Remaining in Phase 3: `group.zig` (sub-windows), public APIs for the other row
layouts (ratio rows, `layoutSpace`, template), and the bits deferred until the
widgets exist (header close/minimize buttons, scrollbars, resize scaler).

Memory-model decisions for the idiomatic core (replacing Nuklear's
pool/page/freelist machinery):
- **No `nk_pool`/`nk_page_element`.** Windows/panels/tables are allocated
  directly via `std.mem.Allocator`. (The deferred `pool`/`page_element` port is
  thus dropped — superseded by idiomatic allocation.)
- **Windows**: owned by `Context`; looked up by name via
  `std.StringHashMapUnmanaged(*Window)` (or hashed id), kept in an explicit
  z-order list. Replaces the `begin/end/prev/next` intrusive list.
- **Per-window widget state** (`nk_table`: hash→u32 for scroll offsets, tree
  collapse states): an `AutoHashMapUnmanaged` with per-entry `seq` for the
  end-of-frame GC. Nuklear hands out interior `nk_uint*` that the panel writes
  through; the port will instead resolve by id at panel begin/end (so the API
  ties into `panel.zig` and is built with it, not standalone).
- **Command output**: each `Window` owns a `CommandBuffer` (already an
  `ArrayList`); the context iterates windows in z-order to produce the final
  command stream, instead of carving one shared byte buffer with begin/end
  offsets.
- **Config (style push/pop) stacks**: bounded arrays sized as upstream.

**Phase 4 — Widgets** 🚧 in progress
Done: `widget.zig` (shared LayoutState/ButtonBehavior/States), `text.zig`
(label), `button.zig` (text + symbol button), `toggle.zig` (checkbox/radio),
`slider.zig`, `progress.zig`, `symbol.zig` (`nk_draw_symbol`), `scrollbar.zig`
(v/h). Panel header close/minimize buttons and window scrollbars are now
re-enabled (the deferred Phase-3 pieces). Pattern: pure low-level `do*`/`draw*`
module + thin `Context` methods that allocate a slot via `widget()`.
Remaining: `selectable`, `knob`, `property`, `edit` + `text_editor`, `combo`,
`contextual`, `menu`, `tooltip`, `tree`, `chart`, `popup`, `table`,
`list_view`, `color_picker`, image/9slice widgets, `group` (sub-windows), and
the window resize scaler.

CI: `.github/workflows/ci.yml` runs `zig build test`, `zig fmt --check` and a
docs deploy; `zig build docs` emits the autodoc site.

**Phase 5 — Font**
`rect_pack.zig` (idiomatic Zig port of stb_rect_pack). `stb_truetype.h` kept as C,
integrated through `build.zig` and wrapped by `font.zig` (atlas baking). Also port
the user-font interface so apps can supply their own font.

**Phase 6 — Vertex / draw list**
`vertex.zig` (convert `Command` buffer → vertex/index buffers for HW renderers).

**Phase 7 — wio renderer (later, per request)**
`renderers/wio.zig`: rasterize the command buffer to a wio software `Framebuffer`
(and/or a GL renderer via the Phase 6 vertex output). Example app under `examples/`.

## Commit policy

Conventional Commits, committed inside the `zuklear/` git repo. Author = repo
owner; **never** authored by Claude, no AI co-author trailer. One commit per
coherent unit (a module + its tests).
