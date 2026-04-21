const std = @import("std");
const builtin = @import("builtin");

const required_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };

comptime {
    if (builtin.zig_version.order(required_zig) != .eq) {
        @compileError(std.fmt.comptimePrint(
            "smithers-cli requires Zig {}. You have {}.",
            .{ required_zig, builtin.zig_version },
        ));
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    }).module("clap");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clap", .module = clap },
        },
    });

    const exe = b.addExecutable(.{
        .name = "smithers-cli",
        .root_module = exe_mod,
    });
    exe.linkLibC();
    exe.linkSystemLibrary("sqlite3");
    exe.addObjectFile(b.path("../zig-out/lib/libsmithers.a"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run smithers-cli");
    run_step.dependOn(&run_cmd.step);

    const unit_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clap", .module = clap },
        },
    });
    const unit = b.addTest(.{ .root_module = unit_mod });
    unit.linkLibC();
    unit.linkSystemLibrary("sqlite3");
    unit.addObjectFile(b.path("../zig-out/lib/libsmithers.a"));
    const run_unit = b.addRunArtifact(unit);

    const args_test_mod = b.createModule(.{
        .root_source_file = b.path("test/args.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "clap", .module = clap },
            .{ .name = "smithers_cli", .module = unit_mod },
        },
    });
    const args_test = b.addTest(.{ .root_module = args_test_mod });
    args_test.linkLibC();
    args_test.linkSystemLibrary("sqlite3");
    args_test.addObjectFile(b.path("../zig-out/lib/libsmithers.a"));
    const run_args_test = b.addRunArtifact(args_test);

    const e2e_options = b.addOptions();
    e2e_options.addOptionPath("exe_path", exe.getEmittedBin());
    const e2e_mod = b.createModule(.{
        .root_source_file = b.path("test/e2e.zig"),
        .target = target,
        .optimize = optimize,
    });
    e2e_mod.addOptions("build_options", e2e_options);
    const e2e = b.addTest(.{ .root_module = e2e_mod });
    const run_e2e = b.addRunArtifact(e2e);

    const test_step = b.step("test", "Run smithers-cli unit and e2e tests");
    test_step.dependOn(&run_unit.step);
    test_step.dependOn(&run_args_test.step);
    test_step.dependOn(&run_e2e.step);
}
