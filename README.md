# zuklear

An **idiomatic** Zig 0.16.0 port of [Nuklear](https://github.com/Immediate-Mode-UI/Nuklear),
the single-header immediate-mode GUI library. This is a native rewrite, not a
`@cImport` wrapper: the API uses Zig allocators, error unions, methods, tagged
unions and flag structs.

> Status: **early, in progress.** See [`PLAN.md`](PLAN.md) for the roadmap and
> which modules have landed.

## Build

```sh
zig build test            # run the test suite
zig build run-example     # software-rendered wio demo
zig build run-example-gl  # OpenGL-rendered wio demo
```

Requires Zig `0.16.0`. The demo depends on [wio](https://github.com/ypsvlq/wio)
(a path dependency); the library itself has no dependencies.

## Status

Phases 1–4 (foundations, drawing/input, context+layout, widgets) and a software
renderer with a wio demo are implemented. See [`PLAN.md`](PLAN.md). Widgets:
label, button, checkbox, radio, slider, progress, knob, scrollbar, selectable,
tree, group, combo, menu, image, chart, color picker, single-line text edit and
numeric property — rendered to a window via `render.software` + the built-in
bitmap font.

## License

Dual **MIT / Public Domain (Unlicense)**, matching upstream Nuklear — see
[`LICENSE`](LICENSE). Third-party credits are in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
