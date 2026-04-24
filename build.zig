//! Makefile-style entrypoint for SmithersGUI.
//!
//! Common commands:
//!   zig build           build SmithersGUI (default)
//!   zig build test      run swift tests
//!   zig build swift     build the Swift app only
//!   zig build xcode     build via xcodebuild (release)
//!   zig build ghostty   (re)build the Ghostty xcframework (slow)
//!   zig build libsmithers build the libsmithers static archive
//!   zig build xcodegen  regenerate SmithersGUI.xcodeproj from project.yml
//!   zig build clean     remove build artifacts
//!   zig build run       build then launch .build/debug/SmithersGUI
//!   zig build everything-up
//!                       bring up the full dev stack: plue docker-compose
//!                       backend, seed a test user/token, build SmithersiOS,
//!                       boot an iPhone simulator, and launch the app signed
//!                       in against the local backend.
//!                       Override plue location with PLUE_CHECKOUT=/path.

const std = @import("std");
const builtin = @import("builtin");

/// Pinned Zig version. Matches ghostty's `minimum_zig_version` and the
/// value in `.zigversion`. Zig has no official LTS, so we pin explicitly
/// to keep everyone on the same toolchain.
const required_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };

comptime {
    if (builtin.zig_version.order(required_zig) != .eq) {
        const msg = std.fmt.comptimePrint(
            "This project requires Zig {}. You have {}. " ++
                "Run `zvm use {}` (or see .zigversion).",
            .{ required_zig, builtin.zig_version, required_zig },
        );
        @compileError(msg);
    }
}

const xcframework_lib = "ghostty/macos/GhosttyKit.xcframework/macos-arm64/libghostty-fat.a";

fn ensureGhostty(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
    std.fs.cwd().access(xcframework_lib, .{}) catch {
        return step.fail(
            \\
            \\{s} is missing.
            \\       Build it once with:  zig build ghostty
            \\       (slow; requires Zig 0.15.2 and the macOS SDK on PATH)
            \\
        , .{xcframework_lib});
    };
}

/// Sentinel files inside each submodule. If any is missing, the submodule
/// wasn't initialized (clone without --recursive) and every downstream step
/// will fail with a confusing error.
const submodule_sentinels = [_][]const u8{
    "ghostty/build.zig",
};

fn ensureSubmodules(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
    for (submodule_sentinels) |path| {
        std.fs.cwd().access(path, .{}) catch {
            return step.fail(
                \\
                \\{s} is missing — git submodules are not initialized.
                \\       Run:  git submodule update --init --recursive
                \\
            , .{path});
        };
    }
}

pub fn build(b: *std.Build) void {
    const release = b.option(bool, "release", "Build in release mode") orelse false;

    const check_submodules = b.step("check-submodules", "Verify git submodules are initialized");
    check_submodules.makeFn = ensureSubmodules;

    const check_ghostty = b.step("check-ghostty", "Verify GhosttyKit.xcframework exists");
    check_ghostty.makeFn = ensureGhostty;
    check_ghostty.dependOn(check_submodules);

    // ---- libsmithers --------------------------------------------------------
    const libsmithers_build = b.addSystemCommand(&.{ "zig", "build" });
    libsmithers_build.setCwd(b.path("libsmithers"));
    const libsmithers_step = b.step("libsmithers", "Build libsmithers static library");
    libsmithers_step.dependOn(&libsmithers_build.step);

    // ---- swift build --------------------------------------------------------
    // Swift links -lghostty-fat from the xcframework. It's a ~200 MB build
    // output not shipped in the ghostty submodule, so fail loudly up front if
    // it's missing rather than dying inside the Swift linker.
    const swift_build = b.addSystemCommand(&.{ "swift", "build" });
    if (release) swift_build.addArgs(&.{ "-c", "release" });
    swift_build.step.dependOn(check_ghostty);
    swift_build.step.dependOn(libsmithers_step);
    const swift_step = b.step("swift", "Build SmithersGUI via `swift build`");
    swift_step.dependOn(&swift_build.step);

    // ---- xcodebuild ---------------------------------------------------------
    const xcode_build = b.addSystemCommand(&.{
        "xcodebuild",
        "-project",   "SmithersGUI.xcodeproj",
        "-scheme",    "SmithersGUI",
        "-configuration", if (release) "Release" else "Debug",
        "build",
    });
    xcode_build.step.dependOn(check_ghostty);
    xcode_build.step.dependOn(libsmithers_step);
    const xcode_step = b.step("xcode", "Build via xcodebuild");
    xcode_step.dependOn(&xcode_build.step);

    // ---- xcodegen -----------------------------------------------------------
    const xcodegen = b.addSystemCommand(&.{ "xcodegen", "generate" });
    const xcodegen_step = b.step("xcodegen", "Regenerate SmithersGUI.xcodeproj from project.yml");
    xcodegen_step.dependOn(&xcodegen.step);

    // ---- tests --------------------------------------------------------------
    const swift_test = b.addSystemCommand(&.{ "swift", "test" });
    swift_test.step.dependOn(check_ghostty);
    swift_test.step.dependOn(libsmithers_step);

    const test_step = b.step("test", "Run swift tests");
    test_step.dependOn(&swift_test.step);

    // ---- ghostty xcframework (opt-in, slow) ---------------------------------
    // Requires a working Zig toolchain with the macOS SDK patch. Delegates to
    // ghostty's own build system.
    // `-Dxcframework-target=native` is required: ghostty's default is
    // `.universal`, which emits `macos-arm64_x86_64/ghostty-internal.a`.
    // Smithers (and `xcframework_lib` above) expects the single-arch
    // `macos-arm64/libghostty-fat.a` layout produced by the native target.
    const ghostty_build = b.addSystemCommand(&.{
        "zig", "build",
        "-Doptimize=ReleaseFast",
        "-Dapp-runtime=none",
        "-Demit-xcframework=true",
        "-Dxcframework-target=native",
    });
    ghostty_build.setCwd(b.path("ghostty"));
    ghostty_build.step.dependOn(check_submodules);
    const ghostty_step = b.step("ghostty", "Rebuild ghostty/macos/GhosttyKit.xcframework");
    ghostty_step.dependOn(&ghostty_build.step);

    // ---- run ----------------------------------------------------------------
    const run_cmd = b.addSystemCommand(&.{".build/debug/SmithersGUI"});
    run_cmd.step.dependOn(&swift_build.step);
    const run_step = b.step("run", "Build and run SmithersGUI (debug)");
    run_step.dependOn(&run_cmd.step);

    // ---- gtk (Linux shell) --------------------------------------------------
    const gtk_build = b.addSystemCommand(&.{ "zig", "build" });
    gtk_build.setCwd(b.path("linux"));
    const gtk_build_step = b.step("gtk", "Build the GTK/libadwaita Linux shell");
    gtk_build_step.dependOn(&gtk_build.step);

    const gtk_run = b.addSystemCommand(&.{ "zig", "build", "run" });
    gtk_run.setCwd(b.path("linux"));
    const gtk_run_step = b.step("gtk-run", "Build and run the GTK Linux shell");
    gtk_run_step.dependOn(&gtk_run.step);

    // ---- clean --------------------------------------------------------------
    const swift_clean = b.addSystemCommand(&.{ "swift", "package", "clean" });
    const clean_step = b.step("clean", "Remove build artifacts");
    clean_step.dependOn(&swift_clean.step);

    // ---- everything-up ------------------------------------------------------
    // One-shot dev loop: plue backend via docker compose → health check →
    // seed token → xcodebuild SmithersiOS → boot simulator → launch app with
    // E2E bypass env vars so the app is signed-in against the local stack.
    const everything_up = b.step("everything-up", "Bring up plue backend + run iOS sim signed-in against it");
    everything_up.makeFn = everythingUp;

    // ---- default ------------------------------------------------------------
    b.default_step.dependOn(&swift_build.step);
}

// =============================================================================
// everything-up implementation
// =============================================================================

fn everythingUp(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const ally = b.allocator;
    step.result_cached = false;

    // Resolve plue checkout. Default ../plue, override with PLUE_CHECKOUT.
    const plue_path = std.process.getEnvVarOwned(ally, "PLUE_CHECKOUT") catch
        try ally.dupe(u8, "../plue");
    defer ally.free(plue_path);
    std.fs.cwd().access(plue_path, .{}) catch {
        return step.fail(
            "plue checkout not found at {s} — set PLUE_CHECKOUT=/path/to/plue",
            .{plue_path},
        );
    };

    // 1. docker compose up -d --build
    log("==> plue: make docker-up ({s})", .{plue_path});
    try runStream(step, &.{ "make", "docker-up" }, plue_path, null);

    // 2. wait for :4000 to accept requests. Any HTTP response (even 404/401)
    //    counts as "up" — matches the contract in ios/scripts/run-e2e.sh.
    log("==> waiting for plue api on http://localhost:4000", .{});
    try waitForHealth(step);

    // 3. seed a test user + token + workspace. Needs libpq (psql) on PATH;
    //    the default shell doesn't include Homebrew's keg-only libpq.
    log("==> seeding e2e user / token / workspace", .{});
    const seed_out = try runCaptureWithEnv(
        step,
        &.{"ios/scripts/seed-e2e-data.sh"},
        null,
        PathAugment.libpq,
    );
    defer ally.free(seed_out);
    const bearer = (try extractKey(ally, seed_out, "SMITHERS_E2E_BEARER")) orelse
        return step.fail("seed script did not emit SMITHERS_E2E_BEARER:\n{s}", .{seed_out});
    defer ally.free(bearer);
    log("    bearer={s}…", .{bearer[0..@min(bearer.len, 16)]});

    // 4. xcodebuild SmithersiOS for simulator. The iOS target injects the
    //    active SDK's usr/lib into LIBRARY_SEARCH_PATHS, so this build is
    //    robust even when a developer shell exports macOS SDK paths.
    log("==> building SmithersiOS", .{});
    try runStream(step, &.{
        "xcodebuild",
        "-project",       "SmithersGUI.xcodeproj",
        "-scheme",        "SmithersiOS",
        "-configuration", "Debug",
        "-destination",   "generic/platform=iOS Simulator",
        "-derivedDataPath", "build/DerivedData-everything-up",
        "build",
    }, null, null);

    // 5. Boot iPhone simulator. "Unable to boot … Booted" is fine — ignore.
    log("==> booting iPhone 16 Pro simulator", .{});
    try runAllowFail(step, &.{ "xcrun", "simctl", "boot", "iPhone 16 Pro" });
    try runAllowFail(step, &.{ "open", "-a", "Simulator" });

    // 6. Install + relaunch. `booted` resolves to the one booted device.
    const app_path = "build/DerivedData-everything-up/Build/Products/Debug-iphonesimulator/SmithersiOS.app";
    log("==> installing app on simulator", .{});
    try runStream(step, &.{ "xcrun", "simctl", "install", "booted", app_path }, null, null);
    try runAllowFail(step, &.{ "xcrun", "simctl", "terminate", "booted", "com.smithers.ios" });

    log("==> launching SmithersiOS with e2e bypass", .{});
    var launch_env = try std.process.getEnvMap(ally);
    defer launch_env.deinit();
    try launch_env.put("SIMCTL_CHILD_PLUE_E2E_MODE", "1");
    try launch_env.put("SIMCTL_CHILD_SMITHERS_E2E_BEARER", bearer);
    try launch_env.put("SIMCTL_CHILD_PLUE_BASE_URL", "http://localhost:4000");
    try runStream(
        step,
        &.{ "xcrun", "simctl", "launch", "booted", "com.smithers.ios" },
        null,
        &launch_env,
    );

    log("==> ready. Simulator is signed in against plue at :4000.", .{});
    log("    Tear down with:  (cd {s} && make docker-down)", .{plue_path});
}

fn log(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("[everything-up] " ++ fmt ++ "\n", args);
}

/// Run a child with inherited stdio. Fails the step on non-zero exit.
fn runStream(
    step: *std.Build.Step,
    argv: []const []const u8,
    cwd: ?[]const u8,
    env: ?*const std.process.EnvMap,
) !void {
    var child = std.process.Child.init(argv, step.owner.allocator);
    child.cwd = cwd;
    child.env_map = env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    switch (term) {
        .Exited => |code| if (code != 0)
            return step.fail("{s} exited with code {d}", .{ argv[0], code }),
        else => return step.fail("{s} terminated abnormally", .{argv[0]}),
    }
}

/// Capture stdout of a child that is expected to print a small payload.
/// stderr is inherited so errors surface to the user.
fn runCaptureWithEnv(
    step: *std.Build.Step,
    argv: []const []const u8,
    cwd: ?[]const u8,
    augment: PathAugment,
) ![]u8 {
    const ally = step.owner.allocator;
    var env = try std.process.getEnvMap(ally);
    defer env.deinit();
    switch (augment) {
        .none => {},
        .libpq => {
            const old = env.get("PATH") orelse "";
            const new = try std.fmt.allocPrint(
                ally,
                "/opt/homebrew/opt/libpq/bin:/opt/homebrew/bin:/usr/local/bin:{s}",
                .{old},
            );
            defer ally.free(new);
            try env.put("PATH", new);
        },
    }

    const result = try std.process.Child.run(.{
        .allocator = ally,
        .argv = argv,
        .cwd = cwd,
        .env_map = &env,
        .max_output_bytes = 4 * 1024 * 1024,
    });
    defer ally.free(result.stderr);
    errdefer ally.free(result.stdout);

    if (result.stderr.len > 0) {
        std.debug.print("{s}", .{result.stderr});
    }
    switch (result.term) {
        .Exited => |code| if (code != 0)
            return step.fail("{s} exited with code {d}", .{ argv[0], code }),
        else => return step.fail("{s} terminated abnormally", .{argv[0]}),
    }
    return result.stdout;
}

const PathAugment = enum { none, libpq };

/// Spawn a child and discard exit status. Used for idempotent operations
/// (boot an already-booted simulator, terminate a process that may not be
/// running, open Simulator.app when it's already open).
fn runAllowFail(step: *std.Build.Step, argv: []const []const u8) !void {
    var child = std.process.Child.init(argv, step.owner.allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawnAndWait() catch {};
}

/// Poll curl against /api/health for up to 120s. Any HTTP response
/// (including 401/404) counts as "up" — we just need a live TCP peer.
fn waitForHealth(step: *std.Build.Step) !void {
    const ally = step.owner.allocator;
    const deadline_ms: u64 = 120_000;
    var elapsed_ms: u64 = 0;
    while (elapsed_ms < deadline_ms) {
        const result = std.process.Child.run(.{
            .allocator = ally,
            .argv = &.{
                "curl", "-s", "-o", "/dev/null",
                "-w",   "%{http_code}",
                "--max-time", "2",
                "http://localhost:4000/api/health",
            },
        }) catch |err| {
            return step.fail("curl invocation failed: {s}", .{@errorName(err)});
        };
        defer ally.free(result.stdout);
        defer ally.free(result.stderr);
        switch (result.term) {
            .Exited => |code| if (code == 0 and result.stdout.len >= 3) return,
            else => {},
        }
        std.Thread.sleep(2 * std.time.ns_per_s);
        elapsed_ms += 2_000;
    }
    return step.fail("plue api on :4000 did not respond within 120s", .{});
}

fn extractKey(
    ally: std.mem.Allocator,
    kv: []const u8,
    key: []const u8,
) !?[]u8 {
    var it = std.mem.splitScalar(u8, kv, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (std.mem.eql(u8, line[0..eq], key)) {
            return try ally.dupe(u8, line[eq + 1 ..]);
        }
    }
    return null;
}
