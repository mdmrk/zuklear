# Command-stream differential test (zuklear vs Nuklear)

Verifies that zuklear is a faithful port by checking that, given the **same UI
and the same input**, it emits the **same draw-command stream** as upstream
Nuklear.

## Why the command stream (not pixels)

Both libraries turn a UI + input into a list of draw commands (`Command` /
`nk_command`) *before* any tessellation to vertices/pixels. Comparing at the
command level is:

- **renderer-independent** — no GL/framebuffer needed, fully headless;
- **immune to zuklear's intentional deviations** — `std.math` trig, AA fringe and
  the non-AA pixel nudge only happen in the *vertex* stage, so circles/arcs are
  compared as `circle`/`arc` commands with identical bounds.

## Determinism

- **Font:** both sides use Nuklear's default font metrics — a fixed **7px**
  advance, height **13** (ProggyClean is monospaced). `dump_zk.zig` uses a
  `len*7` width function; run `./dump_nk --font` to confirm Nuklear agrees.
- **Input:** a scripted, fixed per-frame input sequence drives both (currently
  one frame, initial collapsed state). Add frames/clicks in both dumpers in
  lockstep to exercise more.
- Coordinates are stored as integers in both command buffers, so there is no
  floating-point noise to normalize.

## Run

```sh
./compare.sh
```

Builds `dump_nk` (Nuklear, via `zig cc -O0`) and `dump_zk` (via `zig build
dump`), runs both, and diffs the canonical output. A clean diff prints
`EQUIVALENT`.

## Known benign divergence

The text **background** color is normalized away before diffing: Nuklear leaves
`text.background` *uninitialized* for `NK_TREE_TAB` headers (the `type==TAB`
branch never sets it), so it reads stack garbage; zuklear sets it to
`window.background`. It is never used to render glyphs, so this is not a real
difference.

## Files

- `dump_nk.c` — Nuklear reference dumper (amalgamation + `demo/common/overview.c`).
- `dump_zk.zig` — zuklear dumper, reusing `examples/wio_opengl/overview.zig`.
- `compare.sh` — build both, normalize, diff.
