const std = @import("std");
const builtin = @import("builtin");

const required_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };
const macos_deployment_target = std.SemanticVersion{ .major = 14, .minor = 0, .patch = 0 };

comptime {
    if (builtin.zig_version.order(required_zig) != .eq) {
        const msg = std.fmt.comptimePrint(
            "zmux requires Zig {}. You have {}. Run `zvm use {}`.",
            .{ required_zig, builtin.zig_version, required_zig },
        );
        @compileError(msg);
    }
}

pub fn build(b: *std.Build) void {
    var target = b.standardTargetOptions(.{});
    if (target.result.os.tag == .macos and target.query.os_version_min == null) {
        var query = target.query;
        query.os_version_min = .{ .semver = macos_deployment_target };
        target = b.resolveTargetQuery(query);
    }
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.addModule("zmux", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.link_libc = true;

    const daemon_mod = createRootModule(b, target, optimize, "src/daemon.zig");
    const daemon = b.addExecutable(.{
        .name = "zmuxd",
        .root_module = daemon_mod,
    });
    linkPtyArtifact(daemon, target);

    const smithers_daemon_mod = createRootModule(b, target, optimize, "src/daemon.zig");
    const smithers_daemon = b.addExecutable(.{
        .name = "smithers-session-daemon",
        .root_module = smithers_daemon_mod,
    });
    linkPtyArtifact(smithers_daemon, target);

    const connect_mod = createConnectModule(b, target, optimize);
    const connect = b.addExecutable(.{
        .name = "zmux-connect",
        .root_module = connect_mod,
    });
    linkPtyArtifact(connect, target);

    const smithers_connect_mod = createConnectModule(b, target, optimize);
    const smithers_connect = b.addExecutable(.{
        .name = "smithers-session-connect",
        .root_module = smithers_connect_mod,
    });
    linkPtyArtifact(smithers_connect, target);

    // iOS cannot spawn local PTY child processes; package artifacts are only
    // installed for desktop/server targets.
    if (target.result.os.tag != .ios) {
        b.installArtifact(daemon);
        b.installArtifact(smithers_daemon);
        b.installArtifact(connect);
        b.installArtifact(smithers_connect);
    }

    const test_step = b.step("test", "Run zmux unit and integration tests");

    const root_tests = b.addTest(.{ .root_module = createRootModule(b, target, optimize, "src/main.zig") });
    linkPtyArtifact(root_tests, target);
    test_step.dependOn(&b.addRunArtifact(root_tests).step);

    const daemon_tests = b.addTest(.{ .root_module = createRootModule(b, target, optimize, "src/daemon.zig") });
    linkPtyArtifact(daemon_tests, target);
    test_step.dependOn(&b.addRunArtifact(daemon_tests).step);

    const connect_tests = b.addTest(.{ .root_module = createConnectModule(b, target, optimize) });
    linkPtyArtifact(connect_tests, target);
    test_step.dependOn(&b.addRunArtifact(connect_tests).step);

    const server_mod = createRootModule(b, target, optimize, "src/server.zig");
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/session_daemon.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zmux_server", .module = server_mod }},
        }),
    });
    linkPtyArtifact(integration_tests, target);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);
}

fn createRootModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root: []const u8,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
    });
    module.link_libc = true;
    return module;
}

fn createConnectModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/connect.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.link_libc = true;
    return module;
}

fn linkPtyArtifact(artifact: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    artifact.linkLibC();
    if (target.result.os.tag == .linux) artifact.linkSystemLibrary("util");
    if (target.result.os.tag == .macos) artifact.linkSystemLibrary("proc");
}
