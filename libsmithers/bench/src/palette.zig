const std = @import("std");
const zbench = @import("zbench");
const common = @import("common.zig");

// Measures the command-palette query + JSON hot path over synthetic backing
// stores. The public ABI has no bulk-load hook for 1k/100k items, so this file
// mirrors the current libsmithers scoring and serialization path while keeping
// fixtures immutable and outside the timed loop.

const narrative =
    "Palette query plus items_json scores and serializes synthetic workspace candidates for 10, 1k, and 100k-item backing stores; the public ABI currently has no safe bulk-load hook.";

const BackingItem = struct {
    id: []u8,
    title: []u8,
    subtitle: []u8,
    kind: []u8,

    fn deinit(self: BackingItem, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.subtitle);
        allocator.free(self.kind);
    }
};

const JsonItem = struct {
    id: []const u8,
    title: []const u8,
    subtitle: []const u8,
    kind: []const u8,
    score: i32,
};

const Fixture = struct {
    items: []BackingItem,
    query: [:0]u8,

    fn create(count: usize, query: []const u8) !*Fixture {
        const allocator = std.heap.c_allocator;
        const fixture = try allocator.create(Fixture);
        errdefer allocator.destroy(fixture);

        const items = try allocator.alloc(BackingItem, count);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| item.deinit(allocator);
            allocator.free(items);
        }

        for (items, 0..) |*item, i| {
            item.* = .{
                .id = try std.fmt.allocPrint(allocator, "workspace:/bench/palette/repo-{d:0>6}", .{i}),
                .title = try std.fmt.allocPrint(allocator, "repo-{d:0>6}", .{i}),
                .subtitle = try std.fmt.allocPrint(allocator, "/bench/palette/repo-{d:0>6}", .{i}),
                .kind = try allocator.dupe(u8, "workspace"),
            };
            initialized += 1;
        }

        fixture.* = .{
            .items = items,
            .query = try allocator.dupeZ(u8, query),
        };
        return fixture;
    }

    fn destroy(self: *Fixture) void {
        const allocator = std.heap.c_allocator;
        for (self.items) |item| item.deinit(allocator);
        allocator.free(self.items);
        allocator.free(self.query);
        allocator.destroy(self);
    }

    fn run(self: *Fixture, allocator: std.mem.Allocator) void {
        var arena = common.freshArena(allocator);
        defer arena.deinit();
        const out = itemsJson(arena.allocator(), self.items, self.query) catch @panic("palette json failed");
        common.consumeBytes(out);
    }
};

var small: ?*Fixture = null;
var medium: ?*Fixture = null;
var large: ?*Fixture = null;

pub fn add(bench: *zbench.Benchmark, registry: *common.Registry) !void {
    small = try Fixture.create(10, "repo-000009");
    try registry.addCleanup(@ptrCast(small.?), cleanupFixture);
    medium = try Fixture.create(1_000, "repo-000999");
    try registry.addCleanup(@ptrCast(medium.?), cleanupFixture);
    large = try Fixture.create(100_000, "repo-099999");
    try registry.addCleanup(@ptrCast(large.?), cleanupFixture);

    try registry.addSimple(bench, .{
        .name = "palette.query_json_10",
        .group = "palette",
        .narrative = narrative,
        .units_per_run = 10,
        .unit = "items",
        .cliff_ns = 10_000_000,
    }, benchSmall, common.default_config);
    try registry.addSimple(bench, .{
        .name = "palette.query_json_1k",
        .group = "palette",
        .narrative = narrative,
        .units_per_run = 1_000,
        .unit = "items",
        .cliff_ns = 10_000_000,
    }, benchMedium, common.withLimits(128, 200_000_000));
    try registry.addSimple(bench, .{
        .name = "palette.query_json_100k",
        .group = "palette",
        .narrative = narrative,
        .units_per_run = 100_000,
        .unit = "items",
        .cliff_ns = 10_000_000,
    }, benchLarge, common.withLimits(16, 500_000_000));
}

fn cleanupFixture(ptr: *anyopaque) void {
    const fixture: *Fixture = @ptrCast(@alignCast(ptr));
    fixture.destroy();
}

fn itemsJson(allocator: std.mem.Allocator, backing: []const BackingItem, query: []const u8) ![]u8 {
    var matches = std.ArrayList(JsonItem).empty;
    defer matches.deinit(allocator);

    for (backing) |item| {
        const maybe_score = score(item.title, item.subtitle, query, 30);
        const final_score = maybe_score orelse continue;
        try matches.append(allocator, .{
            .id = item.id,
            .title = item.title,
            .subtitle = item.subtitle,
            .kind = item.kind,
            .score = final_score,
        });
    }
    std.mem.sort(JsonItem, matches.items, {}, lessThan);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(matches.items, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn score(title: []const u8, subtitle: []const u8, query: []const u8, base: i32) ?i32 {
    const normalized_query = normalizedView(query);
    if (normalized_query.len == 0) return base;

    const haystacks = [_][]const u8{ title, subtitle };
    var best: ?i32 = null;
    for (haystacks) |value| {
        const candidate = normalizedView(value);
        if (candidate.len == 0) continue;

        const s: ?i32 = if (eqlNormalized(candidate, normalized_query))
            0
        else if (startsWithNormalized(candidate, normalized_query))
            8
        else if (containsNormalized(candidate, normalized_query))
            24
        else if (fuzzySubsequenceScore(normalized_query, candidate)) |fuzzy|
            64 + fuzzy
        else
            null;

        if (s) |value_score| best = if (best) |b| @min(b, value_score) else value_score;
    }
    return if (best) |b| base + b else null;
}

fn normalizedView(raw: []const u8) []const u8 {
    return std.mem.trim(u8, raw, &std.ascii.whitespace);
}

fn eqlNormalized(a_raw: []const u8, b_raw: []const u8) bool {
    const a = normalizedView(a_raw);
    const b = normalizedView(b_raw);
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (std.ascii.toLower(left) != std.ascii.toLower(right)) return false;
    }
    return true;
}

fn startsWithNormalized(haystack_raw: []const u8, needle_raw: []const u8) bool {
    const haystack = normalizedView(haystack_raw);
    const needle = normalizedView(needle_raw);
    if (needle.len > haystack.len) return false;
    return eqlNormalized(haystack[0..needle.len], needle);
}

fn containsNormalized(haystack_raw: []const u8, needle_raw: []const u8) bool {
    const haystack = normalizedView(haystack_raw);
    const needle = normalizedView(needle_raw);
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlNormalized(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn fuzzySubsequenceScore(query_raw: []const u8, candidate_raw: []const u8) ?i32 {
    const query = normalizedView(query_raw);
    const candidate = normalizedView(candidate_raw);
    if (query.len == 0) return 0;
    var query_index: usize = 0;
    var positions: [256]usize = undefined;
    var positions_len: usize = 0;
    for (candidate, 0..) |ch_raw, i| {
        if (query_index >= query.len) break;
        if (std.ascii.toLower(ch_raw) != std.ascii.toLower(query[query_index])) continue;
        if (positions_len >= positions.len) return null;
        positions[positions_len] = i;
        positions_len += 1;
        query_index += 1;
    }
    if (query_index != query.len or positions_len == 0) return null;
    const first = positions[0];
    const last = positions[positions_len - 1];
    const span: i32 = @intCast(last - first + 1);
    const gaps = span - @as(i32, @intCast(positions_len));
    return @max(0, @as(i32, @intCast(first)) + (gaps * 6));
}

fn lessThan(_: void, lhs: JsonItem, rhs: JsonItem) bool {
    if (lhs.score != rhs.score) return lhs.score < rhs.score;
    if (!std.mem.eql(u8, lhs.kind, rhs.kind)) return std.mem.lessThan(u8, lhs.kind, rhs.kind);
    return std.mem.lessThan(u8, lhs.title, rhs.title);
}

fn benchSmall(allocator: std.mem.Allocator) void {
    (small orelse @panic("palette small fixture missing")).run(allocator);
}

fn benchMedium(allocator: std.mem.Allocator) void {
    (medium orelse @panic("palette medium fixture missing")).run(allocator);
}

fn benchLarge(allocator: std.mem.Allocator) void {
    (large orelse @panic("palette large fixture missing")).run(allocator);
}
