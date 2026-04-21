const std = @import("std");
const structs = @import("../apprt/structs.zig");
const ffi = @import("../ffi.zig");
const EventStream = @import("event_stream.zig");
const slash = @import("../commands/slash.zig");

const App = @import("../App.zig");

pub const Session = @This();

allocator: std.mem.Allocator,
app: *App,
kind_value: structs.SessionKind,
workspace_path: ?[]u8 = null,
target_id: ?[]u8 = null,
userdata_value: ?*anyopaque = null,
events_stream: *EventStream,
title_cache: []u8,

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
    errdefer if (target_id) |id| allocator.free(id);

    const stream = try EventStream.create(allocator);
    errdefer stream.destroy();

    const title_value = try makeTitle(allocator, opts.kind, target_id);
    errdefer allocator.free(title_value);

    session.* = .{
        .allocator = allocator,
        .app = app,
        .kind_value = opts.kind,
        .workspace_path = workspace_path,
        .target_id = target_id,
        .userdata_value = opts.userdata,
        .events_stream = stream,
        .title_cache = title_value,
    };

    try app.registerSession(session);
    app.sessionRegistered(session);
    return session;
}

pub fn destroy(self: *Session) void {
    self.app.unregisterSession(self);
    self.events_stream.close();
    self.events_stream.release();
    if (self.workspace_path) |path| self.allocator.free(path);
    if (self.target_id) |id| self.allocator.free(id);
    self.allocator.free(self.title_cache);
    self.allocator.destroy(self);
}

pub fn kind(self: *const Session) structs.SessionKind {
    return self.kind_value;
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

pub fn sendText(self: *Session, text: []const u8) void {
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
            return;
        }
    }

    std.json.Stringify.value(.{
        .type = "text",
        .text = text,
    }, .{}, &out.writer) catch return;
    self.events_stream.pushJson(out.written()) catch return;
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
    if (target_id) |id| {
        if (id.len > 0) return std.fmt.allocPrint(allocator, "{s} {s}", .{ label, id });
    }
    return allocator.dupe(u8, label);
}

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
