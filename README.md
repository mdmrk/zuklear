# zuklear

An **idiomatic** Zig 0.16.0 port of [Nuklear](https://github.com/Immediate-Mode-UI/Nuklear),
the single-header immediate-mode GUI library. This is a native rewrite, not a
`@cImport` wrapper: the API uses Zig allocators, error unions, methods, tagged
unions and flag structs.

> Status: **early, in progress.** See [`PLAN.md`](PLAN.md) for the roadmap and
> which modules have landed.

## Build

```sh
zig build test   # run the test suite
```

Requires Zig `0.16.0`.

## License

Dual **MIT / Public Domain (Unlicense)**, matching upstream Nuklear — see
[`LICENSE`](LICENSE). Third-party credits are in
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
