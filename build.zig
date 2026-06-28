const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library: an idiomatic Zig port of Nuklear. Consumers import it with
    // `@import("zuklear")` after adding this package as a dependency.
    const mod = b.addModule("zuklear", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // `zig build test` runs every `test` block reachable from the root module.
    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_mod_tests.step);

    // `zig build docs` generates the autodoc site into `zig-out/docs`.
    const docs_obj = b.addObject(.{ .name = "zuklear", .root_module = mod });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Build and install the documentation");
    docs_step.dependOn(&install_docs.step);

    // `zig build example` runs the wio software-rendered demo. wio is only
    // pulled in here, not by the library, so `zig build test`/`docs` stay
    // dependency-free.
    const example_step = b.step("example", "Run the wio demo");
    const wio_dep = b.dependency("wio", .{ .target = target, .optimize = optimize, .enable_framebuffer = true });
    const example = b.addExecutable(.{
        .name = "zuklear-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/wio/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zuklear", .module = mod },
                .{ .name = "wio", .module = wio_dep.module("wio") },
            },
        }),
    });
    example_step.dependOn(&b.addInstallArtifact(example, .{}).step);

    const run_example = b.addRunArtifact(example);
    const run_example_step = b.step("run-example", "Build and run the wio demo");
    run_example_step.dependOn(&run_example.step);
}
