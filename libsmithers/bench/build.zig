const std = @import("std");
const builtin = @import("builtin");

const required_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };

comptime {
    if (builtin.zig_version.order(required_zig) != .eq) {
        @compileError(std.fmt.comptimePrint(
            "smithers-bench requires Zig {}. You have {}.",
            .{ required_zig, builtin.zig_version },
        ));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode for smithers-bench",
    ) orelse .ReleaseFast;

    const zbench = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    }).module("zbench");

    const smithers_action = b.createModule(.{
        .root_source_file = b.path("../src/apprt/action.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zbench", .module = zbench },
            .{ .name = "smithers_action", .module = smithers_action },
        },
    });
    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "smithers-bench",
        .root_module = exe_mod,
    });
    exe.addObjectFile(b.path("../zig-out/lib/libsmithers.a"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run smithers-bench");
    run_step.dependOn(&run_cmd.step);
}
