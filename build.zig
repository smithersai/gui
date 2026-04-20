//! Makefile-style entrypoint for SmithersGUI.
//!
//! Common commands:
//!   zig build           build codex-ffi + SmithersGUI (default)
//!   zig build test      run cargo tests + swift tests
//!   zig build codex-ffi build the Rust FFI staticlib only
//!   zig build swift     build the Swift app only
//!   zig build xcode     build via xcodebuild (release)
//!   zig build ghostty   (re)build the Ghostty xcframework (slow)
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

pub fn build(b: *std.Build) void {
    const release = b.option(bool, "release", "Build in release mode") orelse false;

    const check_ghostty = b.step("check-ghostty", "Verify GhosttyKit.xcframework exists");
    check_ghostty.makeFn = ensureGhostty;

    // ---- codex-ffi (cargo) --------------------------------------------------
    // Always built release: project.yml / Package.swift link against
    // codex-ffi/target/release/libcodex_ffi.a, so a debug build would leave
    // the Swift target with an unresolved `-lcodex_ffi`.
    const cargo_build_release = b.addSystemCommand(&.{ "cargo", "build", "--release" });
    cargo_build_release.setCwd(b.path("codex-ffi"));
    const codex_ffi_step = b.step("codex-ffi", "Build the codex-ffi Rust staticlib (release)");
    codex_ffi_step.dependOn(&cargo_build_release.step);


    // ---- swift build --------------------------------------------------------
    // Swift links -lghostty-fat from the xcframework. It's a ~200 MB build
    // output not shipped in the ghostty submodule, so fail loudly up front if
    // it's missing rather than dying inside the Swift linker.
    const swift_build = b.addSystemCommand(&.{ "swift", "build" });
    if (release) swift_build.addArgs(&.{ "-c", "release" });
    swift_build.step.dependOn(&cargo_build_release.step);
    swift_build.step.dependOn(check_ghostty);
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
    xcode_build.step.dependOn(&cargo_build_release.step);
    xcode_build.step.dependOn(check_ghostty);
    const xcode_step = b.step("xcode", "Build via xcodebuild");
    xcode_step.dependOn(&xcode_build.step);

    // ---- xcodegen -----------------------------------------------------------
    const xcodegen = b.addSystemCommand(&.{ "xcodegen", "generate" });
    const xcodegen_step = b.step("xcodegen", "Regenerate SmithersGUI.xcodeproj from project.yml");
    xcodegen_step.dependOn(&xcodegen.step);

    // ---- tests --------------------------------------------------------------
    const cargo_test = b.addSystemCommand(&.{ "cargo", "test", "--release" });
    cargo_test.setCwd(b.path("codex-ffi"));

    const swift_test = b.addSystemCommand(&.{ "swift", "test" });
    swift_test.step.dependOn(&cargo_build_release.step);
    swift_test.step.dependOn(check_ghostty);

    const test_step = b.step("test", "Run cargo + swift tests");
    test_step.dependOn(&cargo_test.step);
    test_step.dependOn(&swift_test.step);

    // ---- ghostty xcframework (opt-in, slow) ---------------------------------
    // Requires a working Zig toolchain with the macOS SDK patch. Delegates to
    // ghostty's own build system.
    const ghostty_build = b.addSystemCommand(&.{
        "zig", "build",
        "-Doptimize=ReleaseFast",
        "-Dapp-runtime=none",
        "-Demit-xcframework=true",
    });
    ghostty_build.setCwd(b.path("ghostty"));
    const ghostty_step = b.step("ghostty", "Rebuild ghostty/macos/GhosttyKit.xcframework");
    ghostty_step.dependOn(&ghostty_build.step);

    // ---- run ----------------------------------------------------------------
    const run_cmd = b.addSystemCommand(&.{".build/debug/SmithersGUI"});
    run_cmd.step.dependOn(&swift_build.step);
    const run_step = b.step("run", "Build and run SmithersGUI (debug)");
    run_step.dependOn(&run_cmd.step);

    // ---- clean --------------------------------------------------------------
    const cargo_clean = b.addSystemCommand(&.{ "cargo", "clean" });
    cargo_clean.setCwd(b.path("codex-ffi"));
    const swift_clean = b.addSystemCommand(&.{ "swift", "package", "clean" });
    const clean_step = b.step("clean", "Remove build artifacts");
    clean_step.dependOn(&cargo_clean.step);
    clean_step.dependOn(&swift_clean.step);

    // ---- default ------------------------------------------------------------
    b.default_step.dependOn(&swift_build.step);
}
