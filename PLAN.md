# zuklear — porting plan

An **idiomatic** Zig 0.16.0 port of [Nuklear](https://github.com/Immediate-Mode-UI/Nuklear)
v4.13.3 (single-header immediate-mode GUI in C89). Not a `@cImport` wrapper — the
public API is redesigned to feel native to Zig.

## Fidelity

This is a **faithful, idiomatic 1:1 port** of Nuklear: every widget, the layout
engine, panel/window handling and the draw path reproduce upstream behavior
pixel- and interaction-for-interaction. The translation is idiomatic (methods,
error unions, tagged unions, flag structs, `std.mem.Allocator`, `std` math)
rather than a literal transliteration, but the observable behavior matches the C
reference. Intentional deviations are local and documented (e.g. `std.math` for
sin/cos/sqrt instead of Nuklear's approximations; an allocator-backed memory
model instead of the `nk_pool`/`nk_page_element` machinery; per-window command
buffers instead of one shared byte buffer).

A line-by-line audit against `../src/*.c` confirmed parity across the
foundations, every `do*`/`draw*` widget routine, the row-layout engine,
`nk_widget`, panel begin/end, the non-blocking popup core and the vertex
draw-list (`nk_convert`). The few behavioral divergences found were fixed:
`NK_WINDOW_SCROLL_AUTO_HIDE`, the `NK_WINDOW_DYNAMIC` panel-end fill, and
`nk_property_*` number formatting.

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

**Phase 3 — Context, style, window, panel, layout** ✅ done
`style.zig`, `hash.zig`, `context.zig` (window + panel + layout in one module:
persistent windows with z-order list + name map + seq GC; begin/end; panel
begin/end with header background+title + close/minimize buttons, window
background, border, clip, scrollbars and the resize scaler; the full row-layout
engine — dynamic/static/ratio rows, row begin/push/end, free-placement space,
and template rows — plus `widget` bounds allocation; and `group` sub-windows
via the `Panel.parent` chain with buffer aliasing). Tested: begin/layout/widget/
end, window reuse/GC, header close button, ratio/template rows, scaler drag,
tree state persistence, nested group.
Deferred to later (not blocking): group scrollbars + cross-frame group scroll
persistence (need the sub-window scrollbar path), and the simplified
window-focus/z-order-on-click.

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

**Phase 4 — Widgets** ✅ substantially complete
Done: text/label, button (text + symbol), checkbox/radio (`toggle`), `slider`,
`progress`, `scrollbar` (v/h), `selectable` (text), tree/tab nodes, `group`
(sub-windows), `knob`, `color_picker`, `chart` (line/column), `symbol`
(`nk_draw_symbol`), `edit` + `text_editor` (single-line text input), `combo`
(+ the non-blocking popup subsystem), `menu` (dropdowns), `image`, `property`
(drag + step buttons). Panel header buttons + window scrollbars also re-enabled.
Pattern: pure low-level `do*`/`draw*` module + thin `Context` methods that
allocate a slot via `widget()`; popups are child windows overlaying the parent
buffer (`Window.popup`, GC'd by seq).

Resolved since: text-editor **undo/redo**, **multi-line** editing + vertical
motion, **click-to-position**, single-line **horizontal scroll**; **property
click-to-type** editing; **group scrollbars** + cross-frame scroll persistence;
renderer **arcs/curves** and **images** (software hook + vertex per-batch
textures); `contextual` (right-click) and `tooltip` (via `nonblockBegin`);
blocking `popup`; `list_view` (virtualized over `group`); slider inc/dec buttons
(`show_buttons`). Remaining (minor; reuse existing foundations): image and
9-slice selectable variants, multi-line selection highlight.

CI: `.github/workflows/ci.yml` runs `zig build test`, `zig fmt --check` and a
docs deploy; `zig build docs` emits the autodoc site.

**Phase 5 — Font**
`rect_pack.zig` (idiomatic Zig port of stb_rect_pack). `stb_truetype.h` kept as C,
integrated through `build.zig` and wrapped by `font.zig` (atlas baking). Also port
the user-font interface so apps can supply their own font.

**Phase 6 — Vertex / draw list + GL backend** ✅ done
`render/vertex.zig` triangulates the `Command` list into interleaved vertices
(pos/uv/rgba) + u32 indices + per-clip draw batches (the `nk_convert`
equivalent); solids sample a white texel so one textured shader covers shapes
and text. `examples/wio_opengl/gl.zig` is a fixed-function OpenGL 1.1 renderer
(loads GL via wio, uploads the atlas as an RGBA texture, draws with `glScissor`),
and `examples/wio_opengl/main.zig` is the GL demo (`zig build run-example-gl`).
`zuklear_font.drawListText` provides the text geometry. A modern GLSL/Vulkan
backend would reuse `render/vertex.zig` unchanged. Both renderers now handle
arcs, curves and images; only the renderer-defined `custom` callback is left for
the app to dispatch.

**Phase 7 — wio renderer** ✅ done, then **removed**
A software rasterizer (`render/software.zig`) plus an 8x8 bitmap `UserFont`
(`font/builtin.zig`) and a framebuffer demo once existed. They were **deleted**:
the OpenGL path (`render/vertex` + `examples/wio_opengl`) is the single supported
backend. `zig build example` / `run-example` now build/run the OpenGL demo.

**Phase 5 — Font baking** ✅ done (stb as C)
Both `stb_rect_pack.h` and `stb_truetype.h` are vendored and compiled as C
(`src/font/stb.c`); the optional `zuklear_font` module (`src/font/atlas.zig`)
bakes a TTF into an alpha atlas via `stbtt_PackFontRange`, exposing glyph
metrics, placement quads (UVs) and a `UserFont`. `zuklear_font.drawListText`
emits glyph quads for the vertex draw-list, and `bakeDefault` bakes the embedded
ProggyClean (Nuklear's default font) so the demo matches upstream. The core
`zuklear` module stays pure Zig; libc/stb live only in the opt-in `zuklear_font`
module.

(Note: the earlier "port rect_pack to Zig" decision was changed — both stb
headers are used as C.)

## Commit policy

- **Format: [Conventional Commits](https://www.conventionalcommits.org/).**
  `type(scope): summary` — e.g. `feat(widget): add knob`, `fix(panel): honor
  SCROLL_AUTO_HIDE`, `refactor`, `docs`, `test`, `chore`.
- **Author: the repo owner only.** Every commit is authored by the repo owner.
  **Never** authored or co-authored by Claude/AI — do **not** add a
  `Co-Authored-By` trailer or any "Generated with" line.
- Commit inside the `zuklear/` git repo, one commit per coherent unit (a module
  + its tests, or one self-contained change).
