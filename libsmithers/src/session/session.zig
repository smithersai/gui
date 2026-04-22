const std = @import("std");
const structs = @import("../apprt/structs.zig");
const ffi = @import("../ffi.zig");
const EventStream = @import("event_stream.zig");
const slash = @import("../commands/slash.zig");
const native = @import("native.zig");

const App = @import("../App.zig");

pub const Session = @This();

pub const PersistedMessage = struct {
    id: []const u8,
    role: []const u8,
    content: []const u8,
    @"timestampMs": i64 = 0,
};

pub const PersistedRecord = struct {
    id: []const u8,
    kind: structs.SessionKind = .chat,
    title: []const u8,
    @"targetId": ?[]const u8 = null,
    @"workspacePath": []const u8,
    @"createdAtMs": i64 = 0,
    @"updatedAtMs": i64 = 0,
    messages: []const PersistedMessage = &.{},
};

allocator: std.mem.Allocator,
app: *App,
id_value: []u8,
kind_value: structs.SessionKind,
workspace_path: ?[]u8 = null,
target_id: ?[]u8 = null,
userdata_value: ?*anyopaque = null,
events_stream: *EventStream,
title_cache: []u8,
created_at_ms: i64,
updated_at_ms: i64,
messages: std.ArrayList(PersistedMessage) = .empty,

pub fn create(app: *App, opts: structs.SessionOptions) !*Session {
    const allocator = app.allocator;
    const session = try allocator.create(Session);
    errdefer allocator.destroy(session);

    const active_workspace_path = if (opts.workspace_path == null)
        try app.activeWorkspacePathDup(allocator)
    else
        null;
    defer if (active_workspace_path) |path| allocator.free(path);

    const workspace_path = if (opts.workspace_path) |ptr|
        try allocator.dupe(u8, std.mem.sliceTo(ptr, 0))
    else if (active_workspace_path) |path|
        try allocator.dupe(u8, path)
    else
        null;
    errdefer if (workspace_path) |path| allocator.free(path);

    const target_id = if (opts.target_id) |ptr|
        try allocator.dupe(u8, std.mem.sliceTo(ptr, 0))
    else
        null;
    errdefer if (target_id) |value| allocator.free(value);

    const session_id = try makeSessionID(allocator, opts.kind, target_id);
    errdefer allocator.free(session_id);

    const stream = try EventStream.create(allocator);
    errdefer stream.destroy();

    const title_value = try makeTitle(allocator, opts.kind, target_id);
    errdefer allocator.free(title_value);
    const now_ms = nowMillis();

    session.* = .{
        .allocator = allocator,
        .app = app,
        .id_value = session_id,
        .kind_value = opts.kind,
        .workspace_path = workspace_path,
        .target_id = target_id,
        .userdata_value = opts.userdata,
        .events_stream = stream,
        .title_cache = title_value,
        .created_at_ms = now_ms,
        .updated_at_ms = now_ms,
    };

    try app.registerSession(session);
    app.sessionRegistered(session);
    app.upsertPersistedChatSession(session);
    return session;
}

pub fn createRestored(app: *App, record: PersistedRecord) !*Session {
    const allocator = app.allocator;
    const session = try allocator.create(Session);
    errdefer allocator.destroy(session);

    const session_id = try allocator.dupe(u8, record.id);
    errdefer allocator.free(session_id);
    const workspace_path = try allocator.dupe(u8, record.@"workspacePath");
    errdefer allocator.free(workspace_path);
    const target_id = if (record.@"targetId") |value|
        try allocator.dupe(u8, value)
    else
        null;
    errdefer if (target_id) |value| allocator.free(value);
    const title_value = try allocator.dupe(u8, record.title);
    errdefer allocator.free(title_value);
    const stream = try EventStream.create(allocator);
    errdefer stream.destroy();
    var messages = try duplicateMessages(allocator, record.messages);
    errdefer freeMessages(allocator, &messages);

    session.* = .{
        .allocator = allocator,
        .app = app,
        .id_value = session_id,
        .kind_value = record.kind,
        .workspace_path = workspace_path,
        .target_id = target_id,
        .userdata_value = null,
        .events_stream = stream,
        .title_cache = title_value,
        .created_at_ms = if (record.@"createdAtMs" > 0) record.@"createdAtMs" else nowMillis(),
        .updated_at_ms = if (record.@"updatedAtMs" > 0) record.@"updatedAtMs" else nowMillis(),
        .messages = messages,
    };

    try replayHistory(session);
    try app.registerSession(session);
    app.sessionRegistered(session);
    return session;
}

pub fn destroy(self: *Session) void {
    self.app.unregisterSession(self);
    self.events_stream.close();
    self.events_stream.release();
    self.allocator.free(self.id_value);
    if (self.workspace_path) |path| self.allocator.free(path);
    if (self.target_id) |value| self.allocator.free(value);
    self.allocator.free(self.title_cache);
    freeMessages(self.allocator, &self.messages);
    self.allocator.destroy(self);
}

pub fn kind(self: *const Session) structs.SessionKind {
    return self.kind_value;
}

pub fn sessionID(self: *const Session) []const u8 {
    return self.id_value;
}

pub fn workspacePath(self: *const Session) ?[]const u8 {
    return self.workspace_path;
}

pub fn userdata(self: *const Session) ?*anyopaque {
    return self.userdata_value;
}

pub fn title(self: *const Session) structs.String {
    return ffi.stringDup(self.title_cache);
}

pub fn events(self: *Session) *EventStream {
    return self.events_stream.retain();
}

pub fn matchesPersistedID(self: *const Session, persisted_id: []const u8) bool {
    return std.mem.eql(u8, self.id_value, persisted_id);
}

pub fn persistedRecord(self: *const Session) ?PersistedRecord {
    if (self.kind_value != .chat) return null;
    const workspace_path = self.workspace_path orelse return null;
    return .{
        .id = self.id_value,
        .kind = self.kind_value,
        .title = self.title_cache,
        .@"targetId" = self.target_id,
        .@"workspacePath" = workspace_path,
        .@"createdAtMs" = self.created_at_ms,
        .@"updatedAtMs" = self.updated_at_ms,
        .messages = self.messages.items,
    };
}

pub fn sendText(self: *Session, text: []const u8) void {
    if (self.kind_value == .chat) {
        self.sendChatText(text);
        return;
    }

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();

    if (std.mem.startsWith(u8, std.mem.trim(u8, text, &std.ascii.whitespace), "/")) {
        const parsed = slash.parseToValue(self.allocator, text) catch null;
        if (parsed) |value| {
            defer value.deinit();
            std.json.Stringify.value(.{
                .type = "slashCommand",
                .input = text,
                .parsed = value.value,
            }, .{}, &out.writer) catch return;
            self.events_stream.pushJson(out.written()) catch return;
            self.app.wakeup();
            return;
        }
    }

    std.json.Stringify.value(.{
        .type = "text",
        .text = text,
    }, .{}, &out.writer) catch return;
    self.events_stream.pushJson(out.written()) catch return;
    self.app.wakeup();
}

fn sendChatText(self: *Session, text: []const u8) void {
    const trimmed = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (trimmed.len == 0) return;

    const timestamp_ms = nowMillis();
    const message = blk: {
        const message_id = makeMessageID(self.allocator, self.id_value, self.messages.items.len + 1) catch return;
        errdefer self.allocator.free(message_id);
        const role = self.allocator.dupe(u8, "user") catch return;
        errdefer self.allocator.free(role);
        const content = self.allocator.dupe(u8, trimmed) catch return;
        errdefer self.allocator.free(content);
        break :blk PersistedMessage{
            .id = message_id,
            .role = role,
            .content = content,
            .@"timestampMs" = timestamp_ms,
        };
    };

    self.messages.append(self.allocator, message) catch return;

    self.updated_at_ms = timestamp_ms;
    self.updateChatTitle(trimmed);

    var out: std.Io.Writer.Allocating = .init(self.allocator);
    defer out.deinit();
    if (std.mem.startsWith(u8, trimmed, "/")) {
        const parsed = slash.parseToValue(self.allocator, trimmed) catch null;
        if (parsed) |value| {
            defer value.deinit();
            std.json.Stringify.value(.{
                .type = "slashCommand",
                .input = trimmed,
                .parsed = value.value,
            }, .{}, &out.writer) catch return;
        } else {
            std.json.Stringify.value(self.messages.items[self.messages.items.len - 1], .{}, &out.writer) catch return;
        }
    } else {
        std.json.Stringify.value(self.messages.items[self.messages.items.len - 1], .{}, &out.writer) catch return;
    }
    self.events_stream.pushJson(out.written()) catch return;
    self.app.upsertPersistedChatSession(self);
    self.app.wakeup();
}

fn updateChatTitle(self: *Session, text: []const u8) void {
    if (!std.mem.eql(u8, self.title_cache, "Chat")) return;
    const next = titleFromText(self.allocator, text) catch return;
    self.allocator.free(self.title_cache);
    self.title_cache = next;
}

fn makeTitle(allocator: std.mem.Allocator, session_kind: structs.SessionKind, target_id: ?[]const u8) ![]u8 {
    const label = switch (session_kind) {
        .terminal => "Terminal",
        .chat => "Chat",
        .run_inspect => "Run",
        .workflow => "Workflow",
        .memory => "Memory",
        .dashboard => "Dashboard",
    };
    if (target_id) |value| {
        if (value.len > 0) return std.fmt.allocPrint(allocator, "{s} {s}", .{ label, value });
    }
    return allocator.dupe(u8, label);
}

fn makeSessionID(allocator: std.mem.Allocator, session_kind: structs.SessionKind, target_id: ?[]const u8) ![]u8 {
    if (target_id) |value| {
        if (value.len > 0 and session_kind != .chat) return allocator.dupe(u8, value);
    }
    return std.fmt.allocPrint(allocator, "{s}-{d}", .{ @tagName(session_kind), std.time.microTimestamp() });
}

fn makeMessageID(allocator: std.mem.Allocator, session_id: []const u8, ordinal: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}-message-{d}", .{ session_id, ordinal });
}

fn titleFromText(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var single_line = std.ArrayList(u8).empty;
    defer single_line.deinit(allocator);

    for (text) |byte| {
        const value = if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte;
        try single_line.append(allocator, value);
    }

    const trimmed = std.mem.trim(u8, single_line.items, &std.ascii.whitespace);
    const clipped = if (trimmed.len > 40) trimmed[0..40] else trimmed;
    return allocator.dupe(u8, if (clipped.len == 0) "Chat" else clipped);
}

fn duplicateMessages(
    allocator: std.mem.Allocator,
    source: []const PersistedMessage,
) !std.ArrayList(PersistedMessage) {
    var messages: std.ArrayList(PersistedMessage) = .empty;
    errdefer freeMessages(allocator, &messages);
    try messages.ensureUnusedCapacity(allocator, source.len);
    for (source) |message| {
        const cloned = blk: {
            const message_id = try allocator.dupe(u8, message.id);
            errdefer allocator.free(message_id);
            const role = try allocator.dupe(u8, message.role);
            errdefer allocator.free(role);
            const content = try allocator.dupe(u8, message.content);
            errdefer allocator.free(content);
            break :blk PersistedMessage{
                .id = message_id,
                .role = role,
                .content = content,
                .@"timestampMs" = message.@"timestampMs",
            };
        };
        messages.appendAssumeCapacity(cloned);
    }
    return messages;
}

fn freeMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(PersistedMessage)) void {
    for (messages.items) |message| {
        allocator.free(message.id);
        allocator.free(message.role);
        allocator.free(message.content);
    }
    messages.deinit(allocator);
}

fn replayHistory(self: *Session) !void {
    for (self.messages.items) |message| {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try std.json.Stringify.value(message, .{}, &out.writer);
        try self.events_stream.pushJson(out.written());
    }
}

fn nowMillis() i64 {
    return std.time.milliTimestamp();
}

pub const NativeSessionState = native.NativeSessionState;
pub const NativeSessionOptions = native.NativeSessionOptions;
pub const NativeSession = native.NativeSession;

test "session title uses target id" {
    var app = try App.create(std.testing.allocator, .{});
    defer app.destroy();
    const opts = structs.SessionOptions{ .kind = .run_inspect, .target_id = "run-1" };
    const s = try Session.create(app, opts);
    defer s.destroy();
    const title_s = s.title();
    defer ffi.stringFree(title_s);
    try std.testing.expectEqualStrings("Run run-1", std.mem.sliceTo(title_s.ptr.?, 0));
}
