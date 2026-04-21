const std = @import("std");
const builtin = @import("builtin");

const required_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };

comptime {
    if (builtin.zig_version.order(required_zig) != .eq) {
        const msg = std.fmt.comptimePrint(
            "libsmithers requires Zig {}. You have {}. Run `zvm use {}`.",
            .{ required_zig, builtin.zig_version, required_zig },
        );
        @compileError(msg);
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.link_libc = true;
    root_mod.linkSystemLibrary("sqlite3", .{});

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "smithers",
        .root_module = root_mod,
    });

    b.installArtifact(lib);
    b.getInstallStep().dependOn(&b.addInstallHeaderFile(
        b.path("include/smithers.h"),
        "smithers.h",
    ).step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/e2e.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "libsmithers", .module = root_mod },
            },
        }),
    });
    tests.root_module.link_libc = true;
    tests.root_module.linkSystemLibrary("sqlite3", .{});

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run libsmithers e2e tests");
    test_step.dependOn(&run_tests.step);
}
