const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module — consumers import as @import("electric").
    const mod = b.addModule("electric", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.linkSystemLibrary("sqlite3", .{});

    // In-source tests embedded in src/*.zig.
    const lib_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    lib_tests.linkSystemLibrary("sqlite3");
    lib_tests.linkLibC();
    const run_lib = b.addRunArtifact(lib_tests);

    // Fake-server unit tests: spin up an in-process HTTP server that
    // emits crafted Electric protocol responses. Covers ordering,
    // chunking, reconnection, unsubscribe, bad tokens, malformed frames.
    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/unit_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "electric", .module = mod }},
        }),
    });
    unit.linkSystemLibrary("sqlite3");
    unit.linkLibC();
    const run_unit = b.addRunArtifact(unit);

    // Integration test against a real plue + Electric docker-compose stack.
    // Gated on POC_ELECTRIC_STACK=1 — absent => single passing assertion,
    // present => real HTTP assertions. Same pattern as ticket 0094.
    const integ = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "electric", .module = mod }},
        }),
    });
    integ.linkSystemLibrary("sqlite3");
    integ.linkLibC();
    const run_integ = b.addRunArtifact(integ);

    const test_step = b.step("test", "Run lib + unit + gated integration tests");
    test_step.dependOn(&run_lib.step);
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&run_integ.step);

    const unit_step = b.step("unit", "Lib + fake-server unit tests only");
    unit_step.dependOn(&run_lib.step);
    unit_step.dependOn(&run_unit.step);

    const integ_step = b.step("integration", "Integration tests (POC_ELECTRIC_STACK=1 to exercise live stack)");
    integ_step.dependOn(&run_integ.step);
}
