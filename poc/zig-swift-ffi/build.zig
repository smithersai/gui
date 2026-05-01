//! Build script for the PoC Zig ↔ Swift FFI library.
//!
//! Produces `libffi_poc.a` for three target slices:
//!   - macOS native (arm64)
//!   - aarch64-ios-simulator
//!   - aarch64-ios (device)
//!
//! Usage:
//!   zig build                              # host = native macOS
//!   zig build -Dtarget=aarch64-ios-simulator
//!   zig build -Dtarget=aarch64-ios
//!   zig build test                         # runs on host

const std = @import("std");

const required_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };

comptime {
    const builtin = @import("builtin");
    if (builtin.zig_version.order(required_zig) != .eq) {
        @compileError(std.fmt.comptimePrint(
            "This PoC requires Zig {}. You have {}.",
            .{ required_zig, builtin.zig_version },
        ));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi_poc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const lib = b.addLibrary(.{
        .name = "ffi_poc",
        .root_module = lib_mod,
        .linkage = .static,
    });
    lib.installHeader(b.path("include/ffi_poc.h"), "ffi_poc.h");
    b.installArtifact(lib);

    // Host-only tests.
    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/ffi_poc.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    const tests = b.addTest(.{ .root_module = host_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Zig unit tests for ffi_poc");
    test_step.dependOn(&run_tests.step);
}
