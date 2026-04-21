const std = @import("std");
const builtin = @import("builtin");

const required_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };

comptime {
    if (builtin.zig_version.order(required_zig) != .eq) {
        @compileError(std.fmt.comptimePrint(
            "Smithers GTK requires Zig {}. You have {}.",
            .{ required_zig, builtin.zig_version },
        ));
    }
}

const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};

fn checkGtkDeps(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "pkg-config", "--exists", "gtk4", "libadwaita-1", "gio-2.0", "gobject-2.0", "glib-2.0" },
    }) catch |err| {
        return step.fail(
            "pkg-config is required to build smithers-gtk ({s}). Install pkg-config/pkgconf plus gtk4 and libadwaita development packages.",
            .{@errorName(err)},
        );
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => 1,
    };
    if (exit_code != 0) {
        return step.fail(
            "GTK development packages are missing. `pkg-config --exists gtk4 libadwaita-1 gio-2.0 gobject-2.0 glib-2.0` failed:\n{s}",
            .{result.stderr},
        );
    }
}

fn checkBun(step: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {
    const b = step.owner;
    const result = std.process.Child.run(.{
        .allocator = b.allocator,
        .argv = &.{ "bun", "--version" },
    }) catch |err| {
        return step.fail(
            "bun is required to apply Ghostty embed patches ({s}). Install it with `brew install oven-sh/bun/bun` or `curl -fsSL https://bun.sh/install | bash`.",
            .{@errorName(err)},
        );
    };
    defer b.allocator.free(result.stdout);
    defer b.allocator.free(result.stderr);
    const exit_code = switch (result.term) {
        .Exited => |code| code,
        else => 1,
    };
    if (exit_code != 0) {
        return step.fail(
            "bun is required to apply Ghostty embed patches. Install it with `brew install oven-sh/bun/bun` or `curl -fsSL https://bun.sh/install | bash`.",
            .{},
        );
    }
}

fn libsmithersExists() bool {
    std.fs.cwd().access("../libsmithers/zig-out/lib/libsmithers.a", .{}) catch return false;
    return true;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse false;
    const default_stub = !libsmithersExists();
    const stub_libsmithers = b.option(
        bool,
        "stub-libsmithers",
        "Link the local no-op libsmithers stub instead of ../libsmithers/zig-out/lib/libsmithers.a",
    ) orelse default_stub;

    const check_bun = b.step("check-bun", "Verify bun is available for Ghostty patching");
    check_bun.makeFn = checkBun;

    const apply_ghostty_patches = b.addSystemCommand(&.{ "bun", "linux/scripts/apply-ghostty-patches.ts" });
    apply_ghostty_patches.setCwd(b.path(".."));
    apply_ghostty_patches.step.dependOn(check_bun);

    const ghostty_gtk_build = b.addSystemCommand(&.{
        "zig",
        "build",
        "-Dapp-runtime=gtk",
        "-Demit-exe=false",
    });
    ghostty_gtk_build.setCwd(b.path("../ghostty"));
    ghostty_gtk_build.step.dependOn(&apply_ghostty_patches.step);

    const exe = b.addExecutable(.{
        .name = "smithers-gtk",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    exe.linkLibC();
    // macOS 26 dyld rejects binaries with duplicate LC_LOAD_DYLIB entries.
    // Transitive pkg-config deps from gobject's gtk4/adw1 modules cause many
    // dylibs (gtk-4, libadwaita-1, glib, pango, ...) to appear twice. Tell
    // Apple's linker to strip unreferenced/duplicate dylibs.
    if (target.result.os.tag == .macos) exe.dead_strip_dylibs = true;
    exe.addIncludePath(b.path("../libsmithers/include"));
    addGtkImportsAndLinks(b, exe, target, optimize);
    exe.addLibraryPath(b.path("../ghostty/zig-out/lib"));
    exe.root_module.addRPath(b.path("../ghostty/zig-out/lib"));
    exe.linkSystemLibrary2("ghostty-gtk", dynamic_link_opts);
    exe.step.dependOn(&ghostty_gtk_build.step);
    const check_gtk = b.step("check-gtk-deps", "Verify pkg-config can find GTK4/libadwaita");
    check_gtk.makeFn = checkGtkDeps;
    exe.step.dependOn(check_gtk);

    if (stub_libsmithers) {
        const stub = b.addLibrary(.{
            .name = "smithers_stub",
            .linkage = .static,
            .root_module = b.createModule(.{
                .root_source_file = b.path("stub/libsmithers_stub.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        stub.linkLibC();
        stub.addIncludePath(b.path("../libsmithers/include"));
        exe.linkLibrary(stub);
    } else {
        exe.addObjectFile(b.path("../libsmithers/zig-out/lib/libsmithers.a"));
        exe.linkSystemLibrary("sqlite3");
    }

    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run smithers-gtk");
    run_step.dependOn(&run_cmd.step);

    const unit_mod = b.createModule(.{
        .root_source_file = b.path("test/smoke.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_mod.addImport("models", b.createModule(.{
        .root_source_file = b.path("src/models.zig"),
        .target = target,
        .optimize = optimize,
    }));
    const unit = b.addTest(.{
        .root_module = unit_mod,
    });
    const run_unit = b.addRunArtifact(unit);
    const test_step = b.step("test", "Run non-GTK smoke/unit tests");
    test_step.dependOn(&run_unit.step);

    const tree_state_unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/features/tree_state.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tree_state_unit = b.addRunArtifact(tree_state_unit);
    test_step.dependOn(&run_tree_state_unit.step);

    const shortcuts_mod = b.createModule(.{
        .root_source_file = b.path("src/features/shortcuts.zig"),
        .target = target,
        .optimize = optimize,
    });
    addGtkImportsToModule(b, shortcuts_mod, target, optimize);
    const shortcuts_test_mod = b.createModule(.{
        .root_source_file = b.path("test/shortcuts.zig"),
        .target = target,
        .optimize = optimize,
    });
    shortcuts_test_mod.addImport("shortcuts", shortcuts_mod);
    const shortcuts_unit = b.addTest(.{
        .root_module = shortcuts_test_mod,
    });
    if (target.result.os.tag == .macos) shortcuts_unit.dead_strip_dylibs = true;
    shortcuts_unit.step.dependOn(check_gtk);
    const run_shortcuts_unit = b.addRunArtifact(shortcuts_unit);
    test_step.dependOn(&run_shortcuts_unit.step);
}

fn addGtkImportsAndLinks(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    addGtkImportsToModule(b, step.root_module, target, optimize);
    // The gobject zig dependency's gtk4/adw1 modules already call
    // linkSystemLibrary("gtk-4") and "adwaita-1" via pkg-config. Re-linking
    // them explicitly here produces duplicate LC_LOAD_DYLIB entries that
    // macOS dyld rejects at runtime. Linux linkers dedupe, but it's still
    // redundant — rely on the module imports above.
    _ = dynamic_link_opts;
}

fn addGtkImportsToModule(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const gobject_dep = b.dependency("gobject", .{
        .target = target,
        .optimize = optimize,
    });

    const imports = .{
        .{ "adw", "adw1" },
        .{ "gdk", "gdk4" },
        .{ "gio", "gio2" },
        .{ "glib", "glib2" },
        .{ "gobject", "gobject2" },
        .{ "gtk", "gtk4" },
        .{ "pango", "pango1" },
    };
    inline for (imports) |import| {
        const name, const module_name = import;
        module.addImport(name, gobject_dep.module(module_name));
    }
}
