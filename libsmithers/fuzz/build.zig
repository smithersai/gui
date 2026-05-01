const std = @import("std");
const builtin = @import("builtin");

const required_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };

comptime {
    if (builtin.zig_version.order(required_zig) != .eq) {
        @compileError(std.fmt.comptimePrint(
            "libsmithers fuzz requires Zig {}. You have {}.",
            .{ required_zig, builtin.zig_version },
        ));
    }
}

const FuzzTarget = struct {
    name: []const u8,
    seeds: []const []const u8,
};

const targets = [_]FuzzTarget{
    .{ .name = "slash", .seeds = &.{ "text.txt", "valid-command.txt", "quoted.txt", "malformed-quotes.txt", "unicode.txt", "nul.bin" } },
    .{ .name = "cwd", .seeds = &.{ "empty.txt", "relative.txt", "dotdot.txt", "home.txt", "unicode.txt", "long.txt", "nul.bin" } },
    .{ .name = "client", .seeds = &.{ "unknown-invalid-json.txt", "echo-valid-json.txt", "mock-result.txt", "resolve-cwd.txt", "nul.bin" } },
    .{ .name = "persistence", .seeds = &.{ "empty-array.json", "sessions.json", "object.json", "broken.json", "nul.bin" } },
    .{ .name = "action", .seeds = &.{ "open-url.txt", "toast.txt", "clipboard.txt", "empty.txt", "nul.bin" } },
    .{ .name = "palette", .seeds = &.{ "empty.txt", "terminal.txt", "fuzzy.txt", "unicode.txt", "long.txt", "nul.bin" } },
    .{ .name = "models", .seeds = &.{ "object.json", "array.json", "string.json", "broken.json", "nul.bin" } },
    .{ .name = "event", .seeds = &.{ "events-array.json", "mixed-array.json", "object.json", "broken.json", "nul.bin" } },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const smithers_mod = b.createModule(.{
        .root_source_file = libsmithersRoot(b),
        .target = target,
        .optimize = optimize,
    });
    smithers_mod.link_libc = true;
    smithers_mod.linkSystemLibrary("sqlite3", .{});

    const all_tests = b.step("test", "Run libsmithers fuzz corpus smoke tests");

    inline for (targets) |fuzz_target| {
        const corpus_options = b.addOptions();
        corpus_options.addOption([]const []const u8, "corpus", loadCorpus(b, fuzz_target));

        const test_mod = b.createModule(.{
            .root_source_file = b.path("src/" ++ fuzz_target.name ++ ".zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "libsmithers", .module = smithers_mod },
            },
        });
        test_mod.link_libc = true;
        test_mod.linkSystemLibrary("sqlite3", .{});
        test_mod.addOptions("fuzz_corpus", corpus_options);

        const unit = b.addTest(.{
            .name = "fuzz-" ++ fuzz_target.name,
            .root_module = test_mod,
        });
        const run = b.addRunArtifact(unit);

        const run_step = b.step(
            "run-" ++ fuzz_target.name,
            "Run " ++ fuzz_target.name ++ " fuzz corpus or fuzz it with --fuzz",
        );
        run_step.dependOn(&run.step);
        all_tests.dependOn(&run.step);
    }

    b.getInstallStep().dependOn(all_tests);
}

fn libsmithersRoot(b: *std.Build) std.Build.LazyPath {
    std.fs.cwd().access("../src/main.zig", .{}) catch {
        @panic("expected to run from libsmithers/fuzz with ../src/main.zig available");
    };
    return b.path("../src/main.zig");
}

fn loadCorpus(b: *std.Build, fuzz_target: FuzzTarget) []const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    for (fuzz_target.seeds) |seed| {
        const path = b.pathJoin(&.{ "corpus", fuzz_target.name, seed });
        const bytes = std.fs.cwd().readFileAlloc(b.allocator, path, 1024 * 1024) catch |err| {
            std.debug.panic("failed to read corpus file {s}: {s}", .{ path, @errorName(err) });
        };
        items.append(b.allocator, bytes) catch @panic("OOM");
    }
    return items.toOwnedSlice(b.allocator) catch @panic("OOM");
}
