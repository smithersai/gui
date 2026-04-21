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
    exe.addIncludePath(b.path("../libsmithers/include"));
    addGtkImportsAndLinks(b, exe, target, optimize);
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
}

fn addGtkImportsAndLinks(
    b: *std.Build,
    step: *std.Build.Step.Compile,
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
        const name, const module = import;
        step.root_module.addImport(name, gobject_dep.module(module));
    }

    step.linkSystemLibrary2("gtk4", dynamic_link_opts);
    step.linkSystemLibrary2("libadwaita-1", dynamic_link_opts);
}
