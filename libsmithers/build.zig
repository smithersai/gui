const std = @import("std");
const builtin = @import("builtin");

const required_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };
const macos_deployment_target = std.SemanticVersion{ .major = 14, .minor = 0, .patch = 0 };

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
    var target = b.standardTargetOptions(.{});
    if (target.result.os.tag == .macos and target.query.os_version_min == null) {
        var query = target.query;
        query.os_version_min = .{ .semver = macos_deployment_target };
        target = b.resolveTargetQuery(query);
    }
    const optimize = b.standardOptimizeOption(.{});

    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    configureSQLite(b, root_mod, target);

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

    const daemon_mod = b.createModule(.{
        .root_source_file = b.path("../zmux/src/daemon.zig"),
        .target = target,
        .optimize = optimize,
    });
    daemon_mod.link_libc = true;

    const daemon = b.addExecutable(.{
        .name = "smithers-session-daemon",
        .root_module = daemon_mod,
    });
    if (target.result.os.tag == .linux) daemon.linkSystemLibrary("util");
    if (target.result.os.tag == .macos) daemon.linkSystemLibrary("proc");
    // iOS targets cannot spawn child processes, so the local-PTY helper
    // binaries are macOS/Linux-only. Skip their install step for iOS.
    if (target.result.os.tag != .ios) b.installArtifact(daemon);

    const connect_mod = b.createModule(.{
        .root_source_file = b.path("../zmux/src/connect.zig"),
        .target = target,
        .optimize = optimize,
    });
    connect_mod.link_libc = true;

    const connect = b.addExecutable(.{
        .name = "smithers-session-connect",
        .root_module = connect_mod,
    });
    if (target.result.os.tag == .linux) connect.linkSystemLibrary("util");
    if (target.result.os.tag != .ios) b.installArtifact(connect);

    const connect_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("../zmux/src/connect.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    connect_unit_tests.linkLibC();
    if (target.result.os.tag == .linux) connect_unit_tests.linkSystemLibrary("util");
    const run_connect_unit_tests = b.addRunArtifact(connect_unit_tests);

    const unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    configureSQLite(b, unit_tests.root_module, target);
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const daemon_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("../zmux/src/daemon.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    daemon_unit_tests.linkLibC();
    if (target.result.os.tag == .linux) daemon_unit_tests.linkSystemLibrary("util");
    if (target.result.os.tag == .macos) daemon_unit_tests.linkSystemLibrary("proc");
    const run_daemon_unit_tests = b.addRunArtifact(daemon_unit_tests);

    // Core FFI smoke test — exercises the `smithers_core_*` extern symbols
    // declared by `src/core/ffi.zig`. Uses `test/core/ffi_smoke.zig` as
    // the root with `libsmithers` imported so the `pub export fn` bodies
    // are linked into the test binary.
    const core_ffi_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/core/ffi_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "libsmithers", .module = root_mod }},
        }),
    });
    configureSQLite(b, core_ffi_tests.root_module, target);
    const run_core_ffi_tests = b.addRunArtifact(core_ffi_tests);

    // Ticket 0140 real-transport integration tests. Compile + run
    // unconditionally; the tests themselves detect POC_ELECTRIC_STACK=1
    // and degrade to a passing no-op when the stack isn't up.
    const core_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/core/integration/real_transport.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "libsmithers", .module = root_mod }},
        }),
    });
    configureSQLite(b, core_integration_tests.root_module, target);
    const run_core_integration_tests = b.addRunArtifact(core_integration_tests);

    const test_step = b.step("test", "Run libsmithers modern core tests");
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_daemon_unit_tests.step);
    test_step.dependOn(&run_connect_unit_tests.step);
    test_step.dependOn(&run_core_ffi_tests.step);
    test_step.dependOn(&run_core_integration_tests.step);

    // Dedicated integration test for zmux, the native session daemon package.
    // This test drives zmux/src/server.zig directly (spawning the server on a
    // background thread and exchanging JSON-RPC over a UNIX socket), which
    // requires a module rooted at the test file with server.zig exposed as
    // an import. It runs as a separate artifact so its module scope does not
    // clash with the shared libsmithers root module.
    test_step.dependOn(&(blk: {
        const session_server_mod = b.createModule(.{
            .root_source_file = b.path("../zmux/src/server.zig"),
            .target = target,
            .optimize = optimize,
        });
        session_server_mod.link_libc = true;
        if (target.result.os.tag == .linux) session_server_mod.linkSystemLibrary("util", .{});

        const session_daemon_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("../zmux/test/integration/session_daemon.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zmux_server", .module = session_server_mod }},
            }),
        });
        session_daemon_tests.linkLibC();
        if (target.result.os.tag == .linux) session_daemon_tests.linkSystemLibrary("util");
        if (target.result.os.tag == .macos) session_daemon_tests.linkSystemLibrary("proc");
        const run_session_daemon_tests = b.addRunArtifact(session_daemon_tests);
        break :blk run_session_daemon_tests;
    }).step);
}

fn configureSQLite(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    module.link_libc = true;
    if (target.result.os.tag == .macos or target.result.os.tag == .ios) {
        if (appleSdkRoot(b)) |sdk_root| {
            module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_root, "usr/lib" }) });
        }
    }
    module.linkSystemLibrary("sqlite3", .{});
}

fn appleSdkRoot(b: *std.Build) ?[]const u8 {
    // SDKROOT is the canonical signal — set by xcrun-style invocations and
    // by the iOS xcframework build script. Trust it when libsqlite3 is
    // present, regardless of platform.
    if (b.graph.env_map.get("SDKROOT")) |sdk_root| {
        if (sdkHasSQLite(b, sdk_root)) return sdk_root;
    }

    const candidates = [_][]const u8{
        "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
        "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
    };
    for (candidates) |sdk_root| {
        if (sdkHasSQLite(b, sdk_root)) return sdk_root;
    }
    return null;
}

fn sdkHasSQLite(b: *std.Build, sdk_root: []const u8) bool {
    const sqlite_stub = b.pathJoin(&.{ sdk_root, "usr/lib/libsqlite3.tbd" });
    std.fs.accessAbsolute(sqlite_stub, .{}) catch return false;
    return true;
}
