//! Android core canary build (ticket 0104).
//!
//! Produces a shared library `libsmithers_core.so` targeting
//! `aarch64-linux-android` for loading via JNI from Kotlin.
//!
//! Two modes:
//!
//!   1. Full shared-library build (what CI + Android developers use).
//!      Requires the Android NDK sysroot so Zig can link against Bionic libc
//!      + libdl. Pass `-Dndk=/path/to/ndk` or set `ANDROID_NDK_ROOT` /
//!      `ANDROID_NDK_HOME` in the environment.
//!
//!   2. Static-archive-only build (fallback for environments without the
//!      NDK). Emits `libsmithers_core.a`. This is what runs as a cheap
//!      "did the FFI surface still cross-compile?" check when the NDK is
//!      unavailable — it compiles every symbol in the core for the Android
//!      target but does not link. Gradle ALWAYS uses mode 1; mode 2 is
//!      purely a developer sanity check.
//!
//! Target triple is hardcoded: `aarch64-linux-android`. 32-bit Android
//! (armv7, x86) and x86_64 are intentionally out of scope for this canary —
//! the contract is "the core compiles for modern Android ARM64" which is
//! all Google ships to the Play Store for new apps in 2026.
//!
//! Why `android.29`? See README: matches the `minSdkVersion` in the
//! Kotlin app's `build.gradle.kts`.

const std = @import("std");

const required_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };

comptime {
    const builtin = @import("builtin");
    if (builtin.zig_version.order(required_zig) != .eq) {
        @compileError(std.fmt.comptimePrint(
            "poc/android-core requires Zig {}. You have {}.",
            .{ required_zig, builtin.zig_version },
        ));
    }
}

const android_api: u32 = 29;

pub fn build(b: *std.Build) void {
    // Default target is aarch64-linux-android at API 29. Users can override
    // (e.g., host native for a sanity compile) via `-Dtarget=...`, but the
    // canary's purpose is specifically aarch64-linux-android.
    const default_query = std.Target.Query.parse(.{
        .arch_os_abi = "aarch64-linux-android",
    }) catch @panic("parse target");
    const target = b.standardTargetOptions(.{ .default_target = default_query });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSmall });

    const ndk_opt = b.option([]const u8, "ndk", "Path to the Android NDK root (sysroot parent). Defaults to $ANDROID_NDK_ROOT / $ANDROID_NDK_HOME.");
    const ndk_root = resolveNdkRoot(b, ndk_opt);

    const lib_mod = b.createModule(.{
        // The JNI wrappers `@import("ffi_core")` at build time. The
        // module's root source is the 0095 FFI file, unmodified, living
        // under `poc/zig-swift-ffi/`. This canary intentionally does NOT
        // fork or vendor that file — breaking 0095's FFI must break this
        // build.
        .root_source_file = b.path("src/jni_bindings.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const core_mod = b.createModule(.{
        .root_source_file = b.path("../zig-swift-ffi/src/ffi_poc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    lib_mod.addImport("ffi_core", core_mod);

    if (ndk_root) |sysroot_parent| {
        // Full shared-library build. Point Zig at the NDK's unified sysroot
        // so it can locate Bionic headers and link stubs for the platform
        // API level.
        const sysroot = b.pathJoin(&.{ sysroot_parent, "toolchains", "llvm", "prebuilt", hostTag(), "sysroot" });
        lib_mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "include" }) });
        lib_mod.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "include", "aarch64-linux-android" }) });
        // Link stubs live under `usr/lib/aarch64-linux-android/<api>/`.
        lib_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "lib", "aarch64-linux-android", b.fmt("{d}", .{android_api}) }) });
        lib_mod.linkSystemLibrary("log", .{}); // __android_log_print, if we want it later
        lib_mod.linkSystemLibrary("dl", .{});

        const shared = b.addLibrary(.{
            .name = "smithers_core",
            .root_module = lib_mod,
            .linkage = .dynamic,
        });
        b.installArtifact(shared);
    } else {
        // No NDK: static archive. Proves the source still cross-compiles for
        // aarch64-linux-android; final linking needs the NDK which CI
        // provides.
        const static = b.addLibrary(.{
            .name = "smithers_core",
            .root_module = lib_mod,
            .linkage = .static,
        });
        b.installArtifact(static);

        const warn = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo '[android-core] No Android NDK found; emitted static archive only. Set ANDROID_NDK_ROOT to produce libsmithers_core.so.'",
        });
        b.getInstallStep().dependOn(&warn.step);
    }
}

fn resolveNdkRoot(b: *std.Build, override: ?[]const u8) ?[]const u8 {
    if (override) |p| return p;
    if (std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_ROOT")) |p| {
        return p;
    } else |_| {}
    if (std.process.getEnvVarOwned(b.allocator, "ANDROID_NDK_HOME")) |p| {
        return p;
    } else |_| {}
    return null;
}

fn hostTag() []const u8 {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => "darwin-x86_64", // NDK ships a single universal prebuilts dir named this on macOS.
        .linux => "linux-x86_64",
        .windows => "windows-x86_64",
        else => @panic("unsupported host for Android NDK cross-compile"),
    };
}
