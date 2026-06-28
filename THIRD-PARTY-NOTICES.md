# Third-party notices

zuklear is an idiomatic Zig port and derivative work of the projects below. All
are permissively licensed and compatible with zuklear's dual MIT / Unlicense.

## Nuklear

The GUI design, algorithms and behaviour are ported from Nuklear.

- Upstream: https://github.com/Immediate-Mode-UI/Nuklear
- Version ported: v4.13.3
- Copyright (c) 2017 Micha Mettke
- License: MIT OR Public Domain (Unlicense) — see `LICENSE`

## stb (Sean Barrett, et al.)

Vendored as C source under `src/font/` and compiled into the optional
`zuklear_font` module for TTF baking:

- `stb_rect_pack.h`, `stb_truetype.h` — used as C (impl in `src/font/stb.c`),
  wrapped by `src/font/atlas.zig`.
- License: MIT OR Public Domain

`extra_font/ProggyClean.ttf` (vendored at `src/font/ProggyClean.ttf` for the
bake test) is by Tristan Grimmer, released into the public domain.

## wio

Optional platform/renderer backend (later phase).

- Upstream: https://github.com/ypsvlq/wio
- Copyright (c) Elaine Gibson, et al.
- License: MIT
