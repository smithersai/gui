const std = @import("std");
const ffi = @import("../ffi.zig");

pub const Category = enum(u8) {
    smithers,
    workflow,
    prompt,
    action,

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .smithers => "Smithers",
            .workflow => "Workflow",
            .prompt => "Prompt",
            .action => "Action",
        };
    }

    pub fn rank(self: Category) u8 {
        return switch (self) {
            .smithers => 0,
            .workflow => 1,
            .prompt => 2,
            .action => 3,
        };
    }
};

pub const Command = struct {
    id: []const u8,
    name: []const u8,
    title: []const u8,
    description: []const u8,
    category: Category,
    aliases: []const []const u8,
};

pub const builtins = [_]Command{
    .{ .id = "smithers.dashboard", .name = "dashboard", .title = "Dashboard", .description = "Open the Smithers overview.", .category = .smithers, .aliases = &[_][]const u8{"overview"} },
    .{ .id = "smithers.agents", .name = "agents", .title = "Agents", .description = "Browse available Smithers/external agents.", .category = .smithers, .aliases = &[_][]const u8{"agent"} },
    .{ .id = "smithers.changes", .name = "changes", .title = "Changes", .description = "Open JJHub changes and repository status.", .category = .smithers, .aliases = &[_][]const u8{ "change", "vcs" } },
    .{ .id = "smithers.runs", .name = "runs", .title = "Runs", .description = "Browse workflow runs.", .category = .smithers, .aliases = &[_][]const u8{"run"} },
    .{ .id = "smithers.snapshots", .name = "snapshots", .title = "Snapshots", .description = "Open timeline/snapshots browser.", .category = .smithers, .aliases = &[_][]const u8{"timeline"} },
    .{ .id = "smithers.workflows", .name = "workflows", .title = "Workflows", .description = "Browse registered workflows.", .category = .smithers, .aliases = &[_][]const u8{"workflow"} },
    .{ .id = "smithers.triggers", .name = "triggers", .title = "Triggers", .description = "Manage cron workflow triggers.", .category = .smithers, .aliases = &[_][]const u8{ "trigger", "crons", "cron" } },
    .{ .id = "smithers.jjhub-workflows", .name = "jjhub-workflows", .title = "JJHub Workflows", .description = "Browse and run JJHub workflows for the current repo.", .category = .smithers, .aliases = &[_][]const u8{ "jjhub_workflows", "jjhub-workflow" } },
    .{ .id = "smithers.approvals", .name = "approvals", .title = "Approval Queue", .description = "Show pending Smithers approvals.", .category = .smithers, .aliases = &[_][]const u8{ "approval-queue", "smithers-approvals" } },
    .{ .id = "smithers.prompts", .name = "prompts", .title = "Prompts", .description = "Open the prompt editor and previewer.", .category = .smithers, .aliases = &[_][]const u8{"prompt"} },
    .{ .id = "smithers.scores", .name = "scores", .title = "Scores", .description = "Open the scores dashboard.", .category = .smithers, .aliases = &[_][]const u8{"score"} },
    .{ .id = "smithers.memory", .name = "memory", .title = "Memory", .description = "Browse stored memory facts.", .category = .smithers, .aliases = &[_][]const u8{"memories"} },
    .{ .id = "smithers.search", .name = "search", .title = "Search", .description = "Search Smithers data.", .category = .smithers, .aliases = &[_][]const u8{"find"} },
    .{ .id = "smithers.sql", .name = "sql", .title = "SQL Browser", .description = "Inspect Smithers tables and run read queries.", .category = .smithers, .aliases = &[_][]const u8{ "database", "tables" } },
    .{ .id = "smithers.landings", .name = "landings", .title = "Landings", .description = "Open landing activity.", .category = .smithers, .aliases = &[_][]const u8{"landing"} },
    .{ .id = "smithers.tickets", .name = "tickets", .title = "Tickets", .description = "Open local Smithers tickets.", .category = .smithers, .aliases = &[_][]const u8{"ticket"} },
    .{ .id = "smithers.issues", .name = "issues", .title = "Issues", .description = "Open work items.", .category = .smithers, .aliases = &[_][]const u8{ "tickets", "work-items" } },
    .{ .id = "smithers.workspaces", .name = "workspaces", .title = "Workspaces", .description = "Open JJHub workspaces.", .category = .smithers, .aliases = &[_][]const u8{"workspace"} },
    .{ .id = "smithers.terminal", .name = "terminal", .title = "Terminal", .description = "Open the terminal pane.", .category = .smithers, .aliases = &[_][]const u8{"shell"} },
    .{ .id = "action.debug", .name = "debug", .title = "Developer Debug", .description = "Toggle the developer debug panel.", .category = .action, .aliases = &[_][]const u8{ "dev", "developer" } },
    .{ .id = "action.quit", .name = "quit", .title = "Quit", .description = "Quit the app.", .category = .action, .aliases = &[_][]const u8{"exit"} },
    .{ .id = "action.help", .name = "help", .title = "Help", .description = "Show available slash commands.", .category = .action, .aliases = &[_][]const u8{"commands"} },
};

pub const Parsed = struct {
    command: ?[]const u8,
    rawArgs: []const u8,
    args: []const []const u8,
    mode: []const u8,
    keyValueArgs: []const KeyValue,
};

pub const KeyValue = struct {
    key: []const u8,
    value: []const u8,
};

pub fn parseJson(input: []const u8) ![]u8 {
    const allocator = ffi.allocator;
    var tokens = std.ArrayList([]u8).empty;
    defer freeTokens(allocator, &tokens);
    var kvs = std.ArrayList(KeyValue).empty;
    defer kvs.deinit(allocator);

    const trimmed = std.mem.trim(u8, input, &std.ascii.whitespace);
    if (!std.mem.startsWith(u8, trimmed, "/")) {
        const parsed = Parsed{
            .command = null,
            .rawArgs = "",
            .args = &.{},
            .mode = "text",
            .keyValueArgs = &.{},
        };
        return jsonAlloc(parsed);
    }

    const body = trimmed[1..];
    var name: []const u8 = "";
    var raw_args: []const u8 = "";
    if (body.len > 0) {
        if (std.mem.indexOfAny(u8, body, &std.ascii.whitespace)) |idx| {
            name = body[0..idx];
            raw_args = std.mem.trim(u8, body[idx..], &std.ascii.whitespace);
        } else {
            name = body;
        }
    }

    try quoteAwareTokens(allocator, raw_args, &tokens);
    for (tokens.items) |token| {
        if (std.mem.indexOfScalar(u8, token, '=')) |idx| {
            if (idx == 0) continue;
            try kvs.append(allocator, .{ .key = token[0..idx], .value = token[idx + 1 ..] });
        }
    }

    const parsed = Parsed{
        .command = name,
        .rawArgs = raw_args,
        .args = tokens.items,
        .mode = if (name.len == 0) "slash-empty" else "slash",
        .keyValueArgs = kvs.items,
    };
    return jsonAlloc(parsed);
}

pub fn parseToValue(allocator: std.mem.Allocator, input: []const u8) !std.json.Parsed(std.json.Value) {
    const json = try parseJson(input);
    defer ffi.allocator.free(json);
    return std.json.parseFromSlice(std.json.Value, allocator, json, .{});
}

pub fn matches(allocator: std.mem.Allocator, query: []const u8, out: *std.ArrayList(Command)) !void {
    for (builtins) |cmd| {
        if (try score(allocator, cmd, query)) |_| try out.append(allocator, cmd);
    }
    std.mem.sort(Command, out.items, query, lessThanMatch);
}

fn lessThanMatch(query: []const u8, lhs: Command, rhs: Command) bool {
    const lhs_score = scoreValue(query, lhs);
    const rhs_score = scoreValue(query, rhs);
    if (lhs_score != rhs_score) return lhs_score < rhs_score;
    if (lhs.category != rhs.category) return lhs.category.rank() < rhs.category.rank();
    return std.mem.lessThan(u8, lhs.name, rhs.name);
}

fn scoreValue(query: []const u8, cmd: Command) i32 {
    return (score(ffi.allocator, cmd, query) catch null) orelse std.math.maxInt(i32);
}

pub fn score(allocator: std.mem.Allocator, cmd: Command, raw_query: []const u8) !?i32 {
    const normalized = try normalize(allocator, raw_query);
    defer allocator.free(normalized);
    if (normalized.len == 0) return 100;

    const name = try normalize(allocator, cmd.name);
    defer allocator.free(name);
    if (std.mem.eql(u8, name, normalized)) return 0;
    for (cmd.aliases) |alias| {
        const n = try normalize(allocator, alias);
        defer allocator.free(n);
        if (std.mem.eql(u8, n, normalized)) return 1;
    }
    if (std.mem.startsWith(u8, name, normalized)) return 10;
    for (cmd.aliases) |alias| {
        const n = try normalize(allocator, alias);
        defer allocator.free(n);
        if (std.mem.startsWith(u8, n, normalized)) return 20;
    }

    const title = try normalize(allocator, cmd.title);
    defer allocator.free(title);
    if (std.mem.startsWith(u8, title, normalized)) return 30;

    const haystacks = [_][]const u8{ cmd.name, cmd.title, cmd.description };
    for (haystacks) |value| {
        const n = try normalize(allocator, value);
        defer allocator.free(n);
        if (std.mem.indexOf(u8, n, normalized) != null) return 50;
    }
    for (cmd.aliases) |alias| {
        const n = try normalize(allocator, alias);
        defer allocator.free(n);
        if (std.mem.indexOf(u8, n, normalized) != null) return 50;
    }

    var best: ?i32 = null;
    for (haystacks) |value| {
        const n = try normalize(allocator, value);
        defer allocator.free(n);
        if (fuzzySubsequenceScore(normalized, n)) |s| best = if (best) |b| @min(b, s) else s;
    }
    for (cmd.aliases) |alias| {
        const n = try normalize(allocator, alias);
        defer allocator.free(n);
        if (fuzzySubsequenceScore(normalized, n)) |s| best = if (best) |b| @min(b, s) else s;
    }
    return if (best) |b| 60 + @min(b, 1000) else null;
}

pub fn quoteAwareTokens(allocator: std.mem.Allocator, raw: []const u8, out: *std.ArrayList([]u8)) !void {
    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);
    var quote: ?u8 = null;
    var escaped = false;
    var token_started = false;

    for (raw) |ch| {
        if (escaped) {
            try current.append(allocator, ch);
            token_started = true;
            escaped = false;
            continue;
        }

        if (ch == '\\') {
            escaped = true;
            token_started = true;
            continue;
        }

        if (quote) |active| {
            if (ch == active) {
                quote = null;
            } else {
                try current.append(allocator, ch);
            }
            token_started = true;
            continue;
        }

        if (ch == '"' or ch == '\'') {
            quote = ch;
            token_started = true;
            continue;
        }

        if (std.ascii.isWhitespace(ch)) {
            if (token_started) {
                try out.append(allocator, try current.toOwnedSlice(allocator));
                current = .empty;
                token_started = false;
            }
            continue;
        }

        try current.append(allocator, ch);
        token_started = true;
    }

    if (escaped) try current.append(allocator, '\\');
    if (token_started) try out.append(allocator, try current.toOwnedSlice(allocator));
}

pub fn freeTokens(allocator: std.mem.Allocator, tokens: *std.ArrayList([]u8)) void {
    for (tokens.items) |token| allocator.free(token);
    tokens.deinit(allocator);
}

pub fn normalize(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    const out = try allocator.alloc(u8, trimmed.len);
    for (trimmed, 0..) |ch, i| out[i] = std.ascii.toLower(ch);
    return out;
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
    var adjacency_bonus: i32 = 0;
    var i: usize = 1;
    while (i < positions_len) : (i += 1) {
        if (positions[i] == positions[i - 1] + 1) adjacency_bonus += 1;
    }

    const boundary_bonus: i32 = if (first == 0)
        8
    else if (isSearchBoundary(candidate[first - 1]))
        4
    else
        0;

    return @max(0, @as(i32, @intCast(first)) + (gaps * 6) - adjacency_bonus - boundary_bonus);
}

fn isSearchBoundary(ch: u8) bool {
    return ch == '-' or ch == '_' or ch == '.' or ch == ':' or ch == '/' or std.ascii.isWhitespace(ch);
}

fn jsonAlloc(value: anytype) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(ffi.allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "slash parser handles quoted key values" {
    const json = try parseJson("/workflow:ship env=\"prod west\" dry=true");
    defer ffi.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"workflow:ship\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "prod west") != null);
}

test "slash scoring exact beats prefix" {
    const exact = (try score(std.testing.allocator, builtins[3], "runs")).?;
    const prefix = (try score(std.testing.allocator, builtins[3], "ru")).?;
    try std.testing.expect(exact < prefix);
}
