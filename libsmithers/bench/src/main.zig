const std = @import("std");
const builtin = @import("builtin");
const zbench = @import("zbench");

const common = @import("common.zig");
const capi = common.capi;

const cwd = @import("cwd.zig");
const slash = @import("slash.zig");
const palette = @import("palette.zig");
const client = @import("client.zig");
const stream = @import("stream.zig");
const persistence = @import("persistence.zig");
const json = @import("json.zig");
const action = @import("action.zig");
const lifecycle = @import("lifecycle.zig");

const group_names = [_][]const u8{
    "cwd",
    "slash",
    "palette",
    "client",
    "stream",
    "persistence",
    "json",
    "action",
    "lifecycle",
};

const Invocation = struct {
    group: ?[]const u8 = null,
    help: bool = false,
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stdout_buffer: [8192]u8 = undefined;
    var stderr_buffer: [2048]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    defer stdout_writer.interface.flush() catch {};
    defer stderr_writer.interface.flush() catch {};

    const invocation = parseArgs(if (argv.len > 0) argv[1..] else &.{}) catch |err| {
        try stderr_writer.interface.print("error: {s}\n\n", .{@errorName(err)});
        try printHelp(&stderr_writer.interface);
        std.process.exit(2);
    };
    if (invocation.help) {
        try printHelp(&stdout_writer.interface);
        return;
    }
    if (invocation.group) |group| {
        if (!knownGroup(group)) {
            try stderr_writer.interface.print("error: unknown group '{s}'\n\n", .{group});
            try printHelp(&stderr_writer.interface);
            std.process.exit(2);
        }
    }

    if (capi.smithers_init(0, null) != 0) return error.SmithersInitFailed;

    var registry = common.Registry.init(allocator);
    defer registry.deinit();

    var bench = zbench.Benchmark.init(allocator, common.default_config);
    defer bench.deinit();

    try addSelected(invocation.group, &bench, &registry);
    try runBenchmarks(allocator, &bench, &registry, invocation.group, &stdout_writer.interface);
}

fn parseArgs(args: []const []const u8) !Invocation {
    var invocation = Invocation{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            invocation.help = true;
        } else if (std.mem.eql(u8, arg, "--group")) {
            i += 1;
            if (i >= args.len) return error.MissingGroupName;
            invocation.group = args[i];
        } else {
            return error.UnknownArgument;
        }
    }
    return invocation;
}

fn printHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: smithers-bench [--group NAME]
        \\
        \\Groups:
        \\
    );
    for (group_names) |name| try writer.print("  {s}\n", .{name});
}

fn knownGroup(group: []const u8) bool {
    for (group_names) |candidate| {
        if (std.mem.eql(u8, group, candidate)) return true;
    }
    return false;
}

fn selected(want: ?[]const u8, group: []const u8) bool {
    return if (want) |name| std.mem.eql(u8, name, group) else true;
}

fn addSelected(want: ?[]const u8, bench: *zbench.Benchmark, registry: *common.Registry) !void {
    if (selected(want, "cwd")) try cwd.add(bench, registry);
    if (selected(want, "slash")) try slash.add(bench, registry);
    if (selected(want, "palette")) try palette.add(bench, registry);
    if (selected(want, "client")) try client.add(bench, registry);
    if (selected(want, "stream")) try stream.add(bench, registry);
    if (selected(want, "persistence")) try persistence.add(bench, registry);
    if (selected(want, "json")) try json.add(bench, registry);
    if (selected(want, "action")) try action.add(bench, registry);
    if (selected(want, "lifecycle")) try lifecycle.add(bench, registry);
}

fn runBenchmarks(
    allocator: std.mem.Allocator,
    bench: *const zbench.Benchmark,
    registry: *const common.Registry,
    group: ?[]const u8,
    writer: *std.Io.Writer,
) !void {
    try writer.print("smithers-bench zbench=0.11.2 zig={f}\n", .{builtin.zig_version});
    try writer.print("group={s}\n", .{group orelse "all"});
    try writer.writeAll("allocations are zbench allocator counts; libsmithers C-allocator return values are freed but not visible to the tracker.\n");
    try writer.writeAll("zbench calibration runs act as warm-up before measured readings.\n\n");
    try writer.writeAll("benchmark                         runs      ns/op       stddev     allocs/op     bytes/op        throughput  notes\n");
    try writer.writeAll("-------------------------------------------------------------------------------------------------------------------\n");

    var last_group: []const u8 = "";
    var iter = try bench.iterator();
    while (try iter.next()) |step| switch (step) {
        .progress => |_| {},
        .result => |result| {
            defer result.deinit();
            const meta = registry.metaFor(result.name) orelse common.CaseMeta{
                .name = result.name,
                .group = "unknown",
                .narrative = "",
            };
            if (!std.mem.eql(u8, last_group, meta.group)) {
                last_group = meta.group;
                try writer.print("\n[{s}] {s}\n", .{ meta.group, meta.narrative });
            }
            try printResult(allocator, writer, result, meta);
        },
    };
}

fn printResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    result: zbench.Result,
    meta: common.CaseMeta,
) !void {
    const timing = try zbench.statistics.Statistics(u64).init(allocator, result.readings.timings_ns);
    const noisy = timing.mean > 0 and timing.stddev * 5 > timing.mean;
    const throughput: f64 = if (timing.mean == 0)
        0
    else
        (meta.units_per_run * 1_000_000_000.0) / @as(f64, @floatFromInt(timing.mean));

    var alloc_count_mean: usize = 0;
    var alloc_bytes_mean: usize = 0;
    if (result.readings.allocations) |allocs| {
        const count_stats = try zbench.statistics.Statistics(usize).init(allocator, allocs.counts);
        const bytes_stats = try zbench.statistics.Statistics(usize).init(allocator, allocs.maxes);
        alloc_count_mean = count_stats.mean;
        alloc_bytes_mean = bytes_stats.mean;
    }

    try writer.print(
        "{s:<32} {d:>5} {d:>12} {d:>12} {d:>12} {d:>12} {d:>14.2} {s}/s  ",
        .{
            meta.name,
            result.readings.iterations,
            timing.mean,
            timing.stddev,
            alloc_count_mean,
            alloc_bytes_mean,
            throughput,
            meta.unit,
        },
    );

    var wrote_note = false;
    if (noisy) {
        try writer.writeAll("noisy; retry with more iterations");
        wrote_note = true;
    }
    if (meta.cliff_ns) |cliff_ns| {
        if (timing.mean > cliff_ns) {
            if (wrote_note) try writer.writeAll("; ");
            try writer.print("cliff >{d}ms", .{cliff_ns / std.time.ns_per_ms});
            wrote_note = true;
        }
    }
    if (!wrote_note) try writer.writeAll("-");
    try writer.writeByte('\n');
}
