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
mutex: std.Thread.Mutex = .{},
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
    self.mutex.lock();
    self.color_scheme = scheme;
    self.mutex.unlock();
    _ = self.performAction(.{ .app = self }, .config_changed);
}

pub fn openWorkspace(self: *App, requested_path: []const u8) !*Workspace {
    const resolved = try cwd.resolve(self.allocator, requested_path);
    var owns_resolved = true;
    errdefer if (owns_resolved) self.allocator.free(resolved);

    self.mutex.lock();
    errdefer self.mutex.unlock();
    var maybe_action_path: ?[]u8 = null;
    errdefer if (maybe_action_path) |path| self.allocator.free(path);
    const ws = blk: {
        if (self.findWorkspaceLocked(resolved)) |existing| {
            maybe_action_path = try self.allocator.dupe(u8, existing.path);
            try self.upsertRecentLocked(resolved);
            self.active_workspace = existing;
            break :blk existing;
        }

        try self.workspaces.ensureUnusedCapacity(self.allocator, 1);
        const created = try self.allocator.create(Workspace);
        errdefer self.allocator.destroy(created);
        created.* = .{ .path = resolved };
        maybe_action_path = try self.allocator.dupe(u8, created.path);
        try self.upsertRecentLocked(created.path);
        self.workspaces.appendAssumeCapacity(created);
        owns_resolved = false;
        self.active_workspace = created;
        break :blk created;
    };
    self.mutex.unlock();
    const action_path = maybe_action_path.?;
    defer self.allocator.free(action_path);

    _ = self.performAction(.{ .app = self }, .{ .open_workspace = action_path });
    self.notifyStateChanged();
    return ws;
}

pub fn closeWorkspace(self: *App, ws: *Workspace) void {
    var removed = false;
    self.mutex.lock();
    var i: usize = 0;
    while (i < self.workspaces.items.len) : (i += 1) {
        if (self.workspaces.items[i] == ws) {
            _ = self.workspaces.orderedRemove(i);
            if (self.active_workspace == ws) {
                self.active_workspace = if (self.workspaces.items.len > 0) self.workspaces.items[0] else null;
            }
            self.allocator.free(ws.path);
            self.allocator.destroy(ws);
            removed = true;
            break;
        }
    }
    self.mutex.unlock();

    if (removed) {
        _ = self.performAction(.{ .app = self }, .close_workspace);
        self.notifyStateChanged();
    }
}

pub fn activeWorkspacePathDup(self: *App, allocator: std.mem.Allocator) !?[]u8 {
    self.mutex.lock();
    defer self.mutex.unlock();
    return if (self.active_workspace) |ws| try allocator.dupe(u8, ws.path) else null;
}

pub fn activeWorkspacePathString(self: *App) structs.String {
    self.mutex.lock();
    defer self.mutex.unlock();
    return ffi.stringDup(if (self.active_workspace) |ws| ws.path else "");
}

pub fn recentWorkspacesJson(self: *App) structs.String {
    const JsonRecent = struct {
        path: []const u8,
        displayName: []const u8,
        lastOpened: i64,
    };

    self.mutex.lock();
    defer self.mutex.unlock();
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
    self.mutex.lock();
    defer self.mutex.unlock();
    try self.sessions.append(self.allocator, session);
}

pub fn sessionRegistered(self: *App, session: *Session) void {
    _ = self.performAction(.{ .session = session }, .new_session);
    self.notifyStateChanged();
}

pub fn unregisterSession(self: *App, session: *Session) void {
    var did_remove = false;
    self.mutex.lock();
    var i: usize = 0;
    while (i < self.sessions.items.len) : (i += 1) {
        if (self.sessions.items[i] == session) {
            _ = self.sessions.orderedRemove(i);
            did_remove = true;
            break;
        }
    }
    self.mutex.unlock();

    if (did_remove) {
        _ = self.performAction(.{ .session = session }, .{ .close_session = session });
        self.notifyStateChanged();
    }
}

pub fn performAction(self: *App, target: action.Target, act: action.Action) bool {
    const cb = self.runtime.action orelse return false;
    var c_action = act.cvalAlloc(self.allocator) catch return false;
    defer c_action.deinit();
    return cb(self, target.cval(), c_action.action);
}

pub fn wakeup(self: *App) void {
    if (self.runtime.wakeup) |cb| cb(self.runtime.userdata);
}

pub fn log(self: *App, level: i32, msg: []const u8) void {
    if (self.runtime.log) |cb| {
        const msg_z = self.allocator.dupeZ(u8, msg) catch return;
        defer self.allocator.free(msg_z);
        cb(self.runtime.userdata, level, msg_z.ptr);
    }
}

pub fn notifyStateChanged(self: *App) void {
    if (self.runtime.state_changed) |cb| cb(self.runtime.userdata);
}

pub fn recentWorkspacesSnapshot(self: *App, allocator: std.mem.Allocator) ![]RecentWorkspace {
    self.mutex.lock();
    defer self.mutex.unlock();

    var out = try allocator.alloc(RecentWorkspace, self.recents.items.len);
    var initialized: usize = 0;
    errdefer {
        for (out[0..initialized]) |recent| {
            allocator.free(recent.path);
            allocator.free(recent.display_name);
        }
        allocator.free(out);
    }
    for (self.recents.items, 0..) |recent, i| {
        const path = try allocator.dupe(u8, recent.path);
        const display_name = allocator.dupe(u8, recent.display_name) catch |err| {
            allocator.free(path);
            return err;
        };
        out[i] = .{
            .path = path,
            .display_name = display_name,
            .last_opened = recent.last_opened,
        };
        initialized += 1;
    }
    return out;
}

pub fn freeRecentWorkspacesSnapshot(allocator: std.mem.Allocator, recents: []RecentWorkspace) void {
    for (recents) |recent| {
        allocator.free(recent.path);
        allocator.free(recent.display_name);
    }
    allocator.free(recents);
}

fn findWorkspaceLocked(self: *const App, path: []const u8) ?*Workspace {
    for (self.workspaces.items) |ws| {
        if (std.mem.eql(u8, ws.path, path)) return ws;
    }
    return null;
}

fn upsertRecentLocked(self: *App, path: []const u8) !void {
    const display = manager.displayName(path);
    const path_copy = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(path_copy);
    const display_copy = try self.allocator.dupe(u8, display);
    errdefer self.allocator.free(display_copy);
    try self.recents.ensureUnusedCapacity(self.allocator, 1);

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

    self.recents.insertAssumeCapacity(0, .{
        .path = path_copy,
        .display_name = display_copy,
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
