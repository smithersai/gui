const std = @import("std");
const structs = @import("apprt/structs.zig");
const action = @import("apprt/action.zig");
const ffi = @import("ffi.zig");
const cwd = @import("workspace/cwd.zig");
const manager = @import("workspace/manager.zig");

const Session = @import("session/session.zig");

pub const Workspace = struct {
    path: []u8,
};

pub const RecentWorkspace = struct {
    path: []u8,
    display_name: []u8,
    last_opened: i64,
};

pub const App = @This();

allocator: std.mem.Allocator,
runtime: structs.RuntimeConfig,
color_scheme: structs.ColorScheme = .light,
workspaces: std.ArrayList(*Workspace) = .empty,
sessions: std.ArrayList(*Session) = .empty,
recents: std.ArrayList(RecentWorkspace) = .empty,
active_workspace: ?*Workspace = null,

pub fn create(allocator: std.mem.Allocator, runtime: structs.RuntimeConfig) !*App {
    const app = try allocator.create(App);
    app.* = .{
        .allocator = allocator,
        .runtime = runtime,
    };
    return app;
}

pub fn destroy(self: *App) void {
    while (self.sessions.items.len > 0) {
        self.sessions.items[0].destroy();
    }
    for (self.workspaces.items) |ws| {
        self.allocator.free(ws.path);
        self.allocator.destroy(ws);
    }
    self.workspaces.deinit(self.allocator);

    for (self.recents.items) |recent| {
        self.allocator.free(recent.path);
        self.allocator.free(recent.display_name);
    }
    self.recents.deinit(self.allocator);
    self.sessions.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn tick(self: *App) void {
    _ = self;
}

pub fn userdata(self: *const App) ?*anyopaque {
    return self.runtime.userdata;
}

pub fn setColorScheme(self: *App, scheme: structs.ColorScheme) void {
    self.color_scheme = scheme;
    _ = self.performAction(.{ .app = self }, .config_changed);
}

pub fn openWorkspace(self: *App, requested_path: []const u8) !*Workspace {
    const resolved = try cwd.resolve(self.allocator, requested_path);
    errdefer self.allocator.free(resolved);

    if (self.findWorkspace(resolved)) |existing| {
        self.active_workspace = existing;
        try self.upsertRecent(resolved);
        _ = self.performAction(.{ .app = self }, .{ .open_workspace = existing.path });
        return existing;
    }

    const ws = try self.allocator.create(Workspace);
    errdefer self.allocator.destroy(ws);
    ws.* = .{ .path = resolved };
    try self.workspaces.append(self.allocator, ws);
    self.active_workspace = ws;
    try self.upsertRecent(ws.path);
    _ = self.performAction(.{ .app = self }, .{ .open_workspace = ws.path });
    self.notifyStateChanged();
    return ws;
}

pub fn closeWorkspace(self: *App, ws: *Workspace) void {
    var i: usize = 0;
    while (i < self.workspaces.items.len) : (i += 1) {
        if (self.workspaces.items[i] == ws) {
            _ = self.workspaces.orderedRemove(i);
            if (self.active_workspace == ws) {
                self.active_workspace = if (self.workspaces.items.len > 0) self.workspaces.items[0] else null;
            }
            self.allocator.free(ws.path);
            self.allocator.destroy(ws);
            _ = self.performAction(.{ .app = self }, .close_workspace);
            self.notifyStateChanged();
            return;
        }
    }
}

pub fn activeWorkspacePath(self: *const App) ?[]const u8 {
    return if (self.active_workspace) |ws| ws.path else null;
}

pub fn activeWorkspacePathString(self: *const App) structs.String {
    return ffi.stringDup(self.activeWorkspacePath() orelse "");
}

pub fn recentWorkspacesJson(self: *const App) structs.String {
    const JsonRecent = struct {
        path: []const u8,
        displayName: []const u8,
        lastOpened: i64,
    };

    var items = self.allocator.alloc(JsonRecent, self.recents.items.len) catch return ffi.stringDup("[]");
    defer self.allocator.free(items);
    for (self.recents.items, 0..) |recent, i| {
        items[i] = .{
            .path = recent.path,
            .displayName = recent.display_name,
            .lastOpened = recent.last_opened,
        };
    }
    return ffi.stringJson(items);
}

pub fn registerSession(self: *App, session: *Session) !void {
    try self.sessions.append(self.allocator, session);
    _ = self.performAction(.{ .session = session }, .new_session);
    self.notifyStateChanged();
}

pub fn unregisterSession(self: *App, session: *Session) void {
    var i: usize = 0;
    while (i < self.sessions.items.len) : (i += 1) {
        if (self.sessions.items[i] == session) {
            _ = self.sessions.orderedRemove(i);
            _ = self.performAction(.{ .session = session }, .{ .close_session = session });
            self.notifyStateChanged();
            return;
        }
    }
}

pub fn performAction(self: *App, target: action.Target, act: action.Action) bool {
    const cb = self.runtime.action orelse return false;
    return cb(self, target.cval(), act.cval());
}

pub fn wakeup(self: *App) void {
    if (self.runtime.wakeup) |cb| cb(self.runtime.userdata);
}

pub fn log(self: *App, level: i32, msg: []const u8) void {
    if (self.runtime.log) |cb| cb(self.runtime.userdata, level, @ptrCast(msg.ptr));
}

pub fn notifyStateChanged(self: *App) void {
    if (self.runtime.state_changed) |cb| cb(self.runtime.userdata);
}

fn findWorkspace(self: *const App, path: []const u8) ?*Workspace {
    for (self.workspaces.items) |ws| {
        if (std.mem.eql(u8, ws.path, path)) return ws;
    }
    return null;
}

fn upsertRecent(self: *App, path: []const u8) !void {
    var i: usize = 0;
    while (i < self.recents.items.len) {
        if (std.mem.eql(u8, self.recents.items[i].path, path)) {
            const recent = self.recents.orderedRemove(i);
            self.allocator.free(recent.path);
            self.allocator.free(recent.display_name);
            continue;
        }
        i += 1;
    }

    const display = manager.displayName(path);
    try self.recents.insert(self.allocator, 0, .{
        .path = try self.allocator.dupe(u8, path),
        .display_name = try self.allocator.dupe(u8, display),
        .last_opened = manager.nowSeconds(),
    });

    while (self.recents.items.len > 20) {
        const removed = self.recents.pop().?;
        self.allocator.free(removed.path);
        self.allocator.free(removed.display_name);
    }
}

test "app opens valid workspace and records recent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);

    var app = try App.create(std.testing.allocator, .{});
    defer app.destroy();
    const ws = try app.openWorkspace(path);
    try std.testing.expectEqualStrings(path, ws.path);
    try std.testing.expectEqual(@as(usize, 1), app.recents.items.len);
}
