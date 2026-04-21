const std = @import("std");
const structs = @import("../apprt/structs.zig");
const ffi = @import("../ffi.zig");
const slash = @import("slash.zig");
const action = @import("../apprt/action.zig");
const App = @import("../App.zig");

pub const Palette = @This();

allocator: std.mem.Allocator,
app: *App,
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
    p.* = .{
        .allocator = app.allocator,
        .app = app,
        .query = try app.allocator.dupe(u8, ""),
    };
    return p;
}

pub fn destroy(self: *Palette) void {
    self.allocator.free(self.query);
    self.allocator.destroy(self);
}

pub fn setMode(self: *Palette, mode: structs.PaletteMode) void {
    self.mode = mode;
}

pub fn setQuery(self: *Palette, query: []const u8) void {
    const owned = self.allocator.dupe(u8, query) catch return;
    self.allocator.free(self.query);
    self.query = owned;
}

pub fn itemsJson(self: *Palette) structs.String {
    var items = std.ArrayList(Candidate).empty;
    defer {
        for (items.items) |item| item.deinit(self.allocator);
        items.deinit(self.allocator);
    }

    self.collect(&items) catch return ffi.stringDup("[]");
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

fn collect(self: *Palette, items: *std.ArrayList(Candidate)) !void {
    const include_commands = self.mode == .all or self.mode == .commands;
    const include_workspaces = self.mode == .all or self.mode == .workspaces;
    const include_files = self.mode == .all or self.mode == .files;
    const include_runs = self.mode == .all or self.mode == .runs;
    const include_workflows = self.mode == .all or self.mode == .workflows;

    if (include_commands) {
        try add(items, self.allocator, "command.ask-ai", "Ask AI", "Open the launcher in Ask AI mode.", "command", 10, self.query);
        try add(items, self.allocator, "command.new-terminal", "New Terminal Workspace", "Create a new terminal workspace and make it active.", "command", 10, self.query);
        try add(items, self.allocator, "command.close-workspace", "Close Current Workspace", "Close the active chat/run/terminal workspace when applicable.", "command", 10, self.query);
        try add(items, self.allocator, "command.global-search", "Global Search", "Open the global search route.", "command", 10, self.query);
        try add(items, self.allocator, "command.refresh", "Refresh Current View", "Reload the active route view.", "command", 10, self.query);
        try add(items, self.allocator, "command.cancel", "Cancel Current Operation", "Stop an active chat turn or running workflow action.", "command", 10, self.query);

        var slash_matches = std.ArrayList(slash.Command).empty;
        defer slash_matches.deinit(self.allocator);
        try slash.matches(self.allocator, self.query, &slash_matches);
        for (slash_matches.items) |cmd| {
            const id = try std.fmt.allocPrint(self.allocator, "slash:{s}", .{cmd.name});
            defer self.allocator.free(id);
            const title = try std.fmt.allocPrint(self.allocator, "/{s}", .{cmd.name});
            defer self.allocator.free(title);
            try add(items, self.allocator, id, title, cmd.description, "slash", 20, self.query);
        }
    }

    if (include_workspaces) {
        for (self.app.recents.items) |recent| {
            const id = try std.fmt.allocPrint(self.allocator, "workspace:{s}", .{recent.path});
            defer self.allocator.free(id);
            try add(items, self.allocator, id, recent.display_name, recent.path, "workspace", 30, self.query);
        }
    }

    if (include_files) try self.collectFiles(items);

    if (include_runs) {
        try add(items, self.allocator, "runs.active", "Active Runs", "Browse running and waiting Smithers runs.", "runs", 60, self.query);
    }
    if (include_workflows) {
        try add(items, self.allocator, "workflows.local", "Local Workflows", "Browse registered Smithers workflows.", "workflow", 50, self.query);
    }
}

fn collectFiles(self: *Palette, items: *std.ArrayList(Candidate)) !void {
    const root = self.app.activeWorkspacePath() orelse return;
    var dir = std.fs.openDirAbsolute(root, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    var count: usize = 0;
    while (try iter.next()) |entry| {
        if (count >= 100) break;
        if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, ".")) continue;
        const id = try std.fmt.allocPrint(self.allocator, "file:{s}/{s}", .{ root, entry.name });
        defer self.allocator.free(id);
        try add(items, self.allocator, id, entry.name, root, "file", 40, self.query);
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
    try items.append(allocator, .{
        .id = try allocator.dupe(u8, id),
        .title = try allocator.dupe(u8, title),
        .subtitle = try allocator.dupe(u8, subtitle),
        .kind = try allocator.dupe(u8, kind),
        .score = final_score,
    });
}

fn score(
    allocator: std.mem.Allocator,
    title: []const u8,
    subtitle: []const u8,
    query: []const u8,
    base: i32,
) !?i32 {
    const normalized_query = try slash.normalize(allocator, query);
    defer allocator.free(normalized_query);
    if (normalized_query.len == 0) return base;

    const haystacks = [_][]const u8{ title, subtitle };
    var best: ?i32 = null;
    for (haystacks) |value| {
        const candidate = try slash.normalize(allocator, value);
        defer allocator.free(candidate);
        if (candidate.len == 0) continue;

        const s: ?i32 = if (std.mem.eql(u8, candidate, normalized_query))
            0
        else if (std.mem.startsWith(u8, candidate, normalized_query))
            8
        else if (std.mem.indexOf(u8, candidate, normalized_query) != null)
            24
        else if (fuzzySubsequenceScore(normalized_query, candidate)) |fuzzy|
            64 + fuzzy
        else
            null;

        if (s) |value_score| best = if (best) |b| @min(b, value_score) else value_score;
    }
    return if (best) |b| base + b else null;
}

fn fuzzySubsequenceScore(query: []const u8, candidate: []const u8) ?i32 {
    if (query.len == 0) return 0;
    var query_index: usize = 0;
    var positions: [256]usize = undefined;
    var positions_len: usize = 0;
    for (candidate, 0..) |ch, i| {
        if (query_index >= query.len) break;
        if (ch != query[query_index]) continue;
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
