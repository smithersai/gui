const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module (client-side WS framing + PTY client).
    const ws_pty_mod = b.addModule("ws_pty", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Library-internal tests: runs tests embedded in src/*.zig files (frame.zig,
    // handshake.zig, client.zig). These exercise the pure-code paths with the
    // Zig test allocator — any leak fails the test.
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    // Unit tests: uses the library as an external module to test the public API.
    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ws_pty", .module = ws_pty_mod },
            },
        }),
    });
    const run_unit = b.addRunArtifact(unit_tests);

    // Integration test: gated behind POC_WS_PTY_STACK=1. Always links, so it is always
    // compiled and exercised; when the env var is absent, body is a cheap no-op assertion.
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "ws_pty", .module = ws_pty_mod },
            },
        }),
    });
    const run_integration = b.addRunArtifact(integration_tests);

    const test_step = b.step("test", "Run all tests (lib + unit + gated integration)");
    test_step.dependOn(&run_lib_tests.step);
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&run_integration.step);

    const unit_step = b.step("unit", "Run library + unit tests (no integration)");
    unit_step.dependOn(&run_lib_tests.step);
    unit_step.dependOn(&run_unit.step);

    const integ_step = b.step("integration", "Run integration tests (set POC_WS_PTY_STACK=1 to exercise live stack)");
    integ_step.dependOn(&run_integration.step);
}
