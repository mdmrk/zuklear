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

Vendored with Nuklear and used by the font phase:

- `stb_rect_pack.h` — ported to idiomatic Zig (`src/font/rect_pack.zig`).
- `stb_truetype.h` — kept as C and integrated via the build; wrapped by
  `src/font/font.zig`.
- License: MIT OR Public Domain

## wio

Optional platform/renderer backend (later phase).

- Upstream: https://github.com/ypsvlq/wio
- Copyright (c) Elaine Gibson, et al.
- License: MIT
