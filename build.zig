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

    // ---- default ------------------------------------------------------------
    b.default_step.dependOn(&swift_build.step);
}
