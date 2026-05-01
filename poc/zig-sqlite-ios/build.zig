//! Build script for the iOS SQLite PoC.
//!
//! Usage:
//!   zig build                              # host = native macOS
//!   zig build -Dtarget=aarch64-ios-simulator
//!   zig build -Dtarget=aarch64-ios
//!   zig build test                         # host tests only

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
        .root_source_file = b.path("src/sqlite_poc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Link against the system libsqlite3.
    //
    // For host (macOS) builds, Zig can resolve -lsqlite3 against the SDK dylib
    // stub. For iOS simulator / device cross-compiles, Zig doesn't ship an
    // iOS sysroot and has no way to find libsqlite3.tbd — but since we build
    // a STATIC archive, we don't actually need to link at lib-emit time.
    // The symbols stay undefined in the `.a`; the final Xcode link (Swift app
    // target) resolves them via `-lsqlite3`, which Xcode wires up to
    // `$(SDKROOT)/usr/lib/libsqlite3.tbd` automatically.
    const t = target.result;
    const is_ios = t.os.tag == .ios;
    if (!is_ios) {
        lib_mod.linkSystemLibrary("sqlite3", .{});
    }

    const lib = b.addLibrary(.{
        .name = "sqlite_poc",
        .root_module = lib_mod,
        .linkage = .static,
    });
    lib.installHeader(b.path("include/sqlite_poc.h"), "sqlite_poc.h");
    b.installArtifact(lib);

    // Host tests.
    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/sqlite_poc.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .link_libc = true,
    });
    host_mod.linkSystemLibrary("sqlite3", .{});
    const tests = b.addTest(.{ .root_module = host_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Zig unit tests for sqlite_poc");
    test_step.dependOn(&run_tests.step);
}
