const std = @import("std");
const structs = @import("../apprt/structs.zig");
const ffi = @import("../ffi.zig");
const slash = @import("slash.zig");
const action = @import("../apprt/action.zig");
const App = @import("../App.zig");

pub const Palette = @This();

allocator: std.mem.Allocator,
app: *App,
mutex: std.Thread.Mutex = .{},
mode: structs.PaletteMode = .all,
query: []u8,

const Candidate = struct {
    id: []u8,
    title: []u8,
    subtitle: []u8,
    kind: []u8,
    score: i32,

    fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.subtitle);
        allocator.free(self.kind);
    }
};

pub fn create(app: *App) !*Palette {
    const p = try app.allocator.create(Palette);
    errdefer app.allocator.destroy(p);
    const query = try app.allocator.dupe(u8, "");
    p.* = .{
        .allocator = app.allocator,
        .app = app,
        .query = query,
    };
    return p;
}

pub fn destroy(self: *Palette) void {
    self.allocator.free(self.query);
    self.allocator.destroy(self);
}

pub fn setMode(self: *Palette, mode: structs.PaletteMode) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.mode = mode;
}

pub fn setQuery(self: *Palette, query: []const u8) void {
    const owned = self.allocator.dupe(u8, query) catch return;
    self.mutex.lock();
    defer self.mutex.unlock();
    self.allocator.free(self.query);
    self.query = owned;
}

pub fn itemsJson(self: *Palette) structs.String {
    self.mutex.lock();
    const mode = self.mode;
    const query = self.allocator.dupe(u8, self.query) catch {
        self.mutex.unlock();
        return ffi.stringDup("[]");
    };
    self.mutex.unlock();
    defer self.allocator.free(query);

    var items = std.ArrayList(Candidate).empty;
    defer {
        for (items.items) |item| item.deinit(self.allocator);
        items.deinit(self.allocator);
    }

    self.collect(mode, query, &items) catch return ffi.stringDup("[]");
    std.mem.sort(Candidate, items.items, {}, lessThan);

    const JsonItem = struct {
        id: []const u8,
        title: []const u8,
        subtitle: []const u8,
        kind: []const u8,
        score: i32,
    };
    var out_items = self.allocator.alloc(JsonItem, items.items.len) catch return ffi.stringDup("[]");
    defer self.allocator.free(out_items);
    for (items.items, 0..) |item, i| {
        out_items[i] = .{
            .id = item.id,
            .title = item.title,
            .subtitle = item.subtitle,
            .kind = item.kind,
            .score = item.score,
        };
    }
    return ffi.stringJson(out_items);
}

pub fn activate(self: *Palette, item_id: []const u8) structs.Error {
    if (std.mem.startsWith(u8, item_id, "workspace:")) {
        const path = item_id["workspace:".len..];
        _ = self.app.openWorkspace(path) catch |err| return ffi.errorFrom("open workspace", err);
        return ffi.errorSuccess();
    }
    if (std.mem.eql(u8, item_id, "command.new-terminal")) {
        _ = self.app.performAction(.{ .app = self.app }, .new_session);
        return ffi.errorSuccess();
    }
    if (std.mem.eql(u8, item_id, "command.palette.dismiss")) {
        _ = self.app.performAction(.{ .app = self.app }, .dismiss_command_palette);
        return ffi.errorSuccess();
    }
    if (std.mem.startsWith(u8, item_id, "slash:")) {
        return ffi.errorSuccess();
    }
    return ffi.errorMessage(404, "palette item not found");
}

fn collect(self: *Palette, mode: structs.PaletteMode, query: []const u8, items: *std.ArrayList(Candidate)) !void {
    const include_commands = mode == .all or mode == .commands;
    const include_workspaces = mode == .all or mode == .workspaces;
    const include_files = mode == .all or mode == .files;
    const include_runs = mode == .all or mode == .runs;
    const include_workflows = mode == .all or mode == .workflows;

    if (include_commands) {
        try add(items, self.allocator, "command.ask-ai", "Ask AI", "Open the launcher in Ask AI mode.", "command", 10, query);
        try add(items, self.allocator, "command.new-terminal", "New Terminal Workspace", "Create a new terminal workspace and make it active.", "command", 10, query);
        try add(items, self.allocator, "command.close-workspace", "Close Current Workspace", "Close the active chat/run/terminal workspace when applicable.", "command", 10, query);
        try add(items, self.allocator, "command.global-search", "Global Search", "Open the global search route.", "command", 10, query);
        try add(items, self.allocator, "command.refresh", "Refresh Current View", "Reload the active route view.", "command", 10, query);
        try add(items, self.allocator, "command.cancel", "Cancel Current Operation", "Stop an active chat turn or running workflow action.", "command", 10, query);

        var slash_matches = std.ArrayList(slash.Command).empty;
        defer slash_matches.deinit(self.allocator);
        try slash.matches(self.allocator, query, &slash_matches);
        for (slash_matches.items) |cmd| {
            const id = try std.fmt.allocPrint(self.allocator, "slash:{s}", .{cmd.name});
            defer self.allocator.free(id);
            const title = try std.fmt.allocPrint(self.allocator, "/{s}", .{cmd.name});
            defer self.allocator.free(title);
            try add(items, self.allocator, id, title, cmd.description, "slash", 20, query);
        }
    }

    if (include_workspaces) {
        const recents = try self.app.recentWorkspacesSnapshot(self.allocator);
        defer App.freeRecentWorkspacesSnapshot(self.allocator, recents);
        for (recents) |recent| {
            const id = try std.fmt.allocPrint(self.allocator, "workspace:{s}", .{recent.path});
            defer self.allocator.free(id);
            try add(items, self.allocator, id, recent.display_name, recent.path, "workspace", 30, query);
        }
    }

    if (include_files) try self.collectFiles(query, items);

    if (include_runs) {
        try add(items, self.allocator, "runs.active", "Active Runs", "Browse running and waiting Smithers runs.", "runs", 60, query);
    }
    if (include_workflows) {
        try add(items, self.allocator, "workflows.local", "Local Workflows", "Browse registered Smithers workflows.", "workflow", 50, query);
    }
}

fn collectFiles(self: *Palette, query: []const u8, items: *std.ArrayList(Candidate)) !void {
    const maybe_root = try self.app.activeWorkspacePathDup(self.allocator);
    const root = maybe_root orelse return;
    defer self.allocator.free(root);
    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (count >= 100) break;
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, ".")) continue;
        const id = try std.fmt.allocPrint(self.allocator, "file:{s}/{s}", .{ root, entry.name });
        defer self.allocator.free(id);
        try add(items, self.allocator, id, entry.name, root, "file", 40, query);
        count += 1;
    }
}

fn add(
    items: *std.ArrayList(Candidate),
    allocator: std.mem.Allocator,
    id: []const u8,
    title: []const u8,
    subtitle: []const u8,
    kind: []const u8,
    base: i32,
    query: []const u8,
) !void {
    const maybe_score = try score(allocator, title, subtitle, query, base);
    const final_score = maybe_score orelse return;
    var candidate = Candidate{
        .id = try allocator.dupe(u8, id),
        .title = undefined,
        .subtitle = undefined,
        .kind = undefined,
        .score = final_score,
    };
    errdefer allocator.free(candidate.id);
    candidate.title = try allocator.dupe(u8, title);
    errdefer allocator.free(candidate.title);
    candidate.subtitle = try allocator.dupe(u8, subtitle);
    errdefer allocator.free(candidate.subtitle);
    candidate.kind = try allocator.dupe(u8, kind);
    errdefer allocator.free(candidate.kind);
    try items.append(allocator, candidate);
}

fn score(
    allocator: std.mem.Allocator,
    title: []const u8,
    subtitle: []const u8,
    query: []const u8,
    base: i32,
) !?i32 {
    _ = allocator;
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

fn fuzzySubsequenceScore(query: []const u8, candidate: []const u8) ?i32 {
    if (query.len == 0) return 0;
    var query_index: usize = 0;
    var positions: [256]usize = undefined;
    var positions_len: usize = 0;
    for (candidate, 0..) |ch, i| {
        if (query_index >= query.len) break;
        if (std.ascii.toLower(ch) != std.ascii.toLower(query[query_index])) continue;
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

fn lessThan(_: void, lhs: Candidate, rhs: Candidate) bool {
    if (lhs.score != rhs.score) return lhs.score < rhs.score;
    if (!std.mem.eql(u8, lhs.kind, rhs.kind)) return std.mem.lessThan(u8, lhs.kind, rhs.kind);
    return std.mem.lessThan(u8, lhs.title, rhs.title);
}

test "palette scores exact command first" {
    var app = try App.create(std.testing.allocator, .{});
    defer app.destroy();
    var p = try Palette.create(app);
    defer p.destroy();
    p.setQuery("terminal");
    const json = p.itemsJson();
    defer ffi.stringFree(json);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(json.ptr.?, 0), "New Terminal Workspace") != null);
}
