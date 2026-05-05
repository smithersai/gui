const std = @import("std");

const buffer = @import("buffer.zig");
const native_mod = @import("native.zig");

const Allocator = std.mem.Allocator;
const NativeSession = native_mod.NativeSession;
const NativeSessionOptions = native_mod.NativeSessionOptions;

pub const Axis = enum {
    horizontal,
    vertical,

    pub fn label(self: Axis) []const u8 {
        return @tagName(self);
    }
};

pub const SpawnSpec = struct {
    title: ?[]u8 = null,
    shell: ?[]u8 = null,
    command: ?[]u8 = null,
    cwd: ?[]u8 = null,
    env: ?[][]const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_bytes: usize = buffer.default_capacity,

    pub fn fromOptions(allocator: Allocator, opts: CreateOptions) !SpawnSpec {
        var spec: SpawnSpec = .{
            .rows = opts.rows,
            .cols = opts.cols,
            .scrollback_bytes = opts.scrollback_bytes,
        };
        errdefer spec.deinit(allocator);

        spec.title = try dupeOpt(allocator, opts.title);
        spec.shell = try dupeOpt(allocator, opts.shell);
        spec.command = try dupeOpt(allocator, opts.command);
        spec.cwd = try dupeOpt(allocator, opts.cwd);
        spec.env = if (opts.env) |entries| try dupeStringSlice(allocator, entries) else null;
        return spec;
    }

    pub fn nativeOptions(self: *const SpawnSpec, id: []const u8, event_sink: ?native_mod.EventSink) NativeSessionOptions {
        return .{
            .id = id,
            .title = self.title,
            .shell = self.shell,
            .command = self.command,
            .cwd = self.cwd,
            .env = self.env,
            .rows = self.rows,
            .cols = self.cols,
            .scrollback_bytes = self.scrollback_bytes,
            .event_sink = event_sink,
        };
    }

    pub fn deinit(self: *SpawnSpec, allocator: Allocator) void {
        if (self.title) |value| allocator.free(value);
        if (self.shell) |value| allocator.free(value);
        if (self.command) |value| allocator.free(value);
        if (self.cwd) |value| allocator.free(value);
        if (self.env) |entries| freeStringSlice(allocator, entries);
        self.* = .{};
    }
};

pub const CreateOptions = struct {
    title: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_bytes: usize = buffer.default_capacity,
};

pub const LayoutNode = union(enum) {
    leaf: []u8,
    split: Split,

    pub const Split = struct {
        id: []u8,
        axis: Axis,
        first: *LayoutNode,
        second: *LayoutNode,
    };

    pub fn leafNode(allocator: Allocator, pane_id: []const u8) !*LayoutNode {
        const node = try allocator.create(LayoutNode);
        errdefer allocator.destroy(node);
        node.* = .{ .leaf = try allocator.dupe(u8, pane_id) };
        return node;
    }

    pub fn deinit(self: *LayoutNode, allocator: Allocator) void {
        switch (self.*) {
            .leaf => |pane_id| allocator.free(pane_id),
            .split => |split| {
                allocator.free(split.id);
                split.first.deinit(allocator);
                allocator.destroy(split.first);
                split.second.deinit(allocator);
                allocator.destroy(split.second);
            },
        }
    }

    pub fn replaceLeafWithSplit(
        self: *LayoutNode,
        allocator: Allocator,
        target_pane_id: []const u8,
        axis: Axis,
        new_pane_id: []const u8,
        split_id: []const u8,
    ) !bool {
        switch (self.*) {
            .leaf => |existing| {
                if (!std.mem.eql(u8, existing, target_pane_id)) return false;

                const first = try LayoutNode.leafNode(allocator, existing);
                errdefer {
                    first.deinit(allocator);
                    allocator.destroy(first);
                }
                const second = try LayoutNode.leafNode(allocator, new_pane_id);
                errdefer {
                    second.deinit(allocator);
                    allocator.destroy(second);
                }
                const owned_split_id = try allocator.dupe(u8, split_id);
                errdefer allocator.free(owned_split_id);

                allocator.free(existing);
                self.* = .{ .split = .{
                    .id = owned_split_id,
                    .axis = axis,
                    .first = first,
                    .second = second,
                } };
                return true;
            },
            .split => |split| {
                if (try split.first.replaceLeafWithSplit(allocator, target_pane_id, axis, new_pane_id, split_id)) {
                    return true;
                }
                return split.second.replaceLeafWithSplit(allocator, target_pane_id, axis, new_pane_id, split_id);
            },
        }
    }

    pub fn removeLeaf(self: *LayoutNode, allocator: Allocator, pane_id: []const u8) bool {
        switch (self.*) {
            .leaf => |existing| return std.mem.eql(u8, existing, pane_id),
            .split => |split| {
                if (split.first.removeLeaf(allocator, pane_id)) {
                    const replacement = split.second.*;
                    split.first.deinit(allocator);
                    allocator.destroy(split.first);
                    allocator.free(split.id);
                    allocator.destroy(split.second);
                    self.* = replacement;
                    return true;
                }
                if (split.second.removeLeaf(allocator, pane_id)) {
                    const replacement = split.first.*;
                    split.second.deinit(allocator);
                    allocator.destroy(split.second);
                    allocator.free(split.id);
                    allocator.destroy(split.first);
                    self.* = replacement;
                    return true;
                }
                return false;
            },
        }
    }

    pub fn writeJson(self: *const LayoutNode, writer: *std.Io.Writer) !void {
        switch (self.*) {
            .leaf => |pane_id| {
                try writer.print("{{\"kind\":\"leaf\",\"paneId\":{f}}}", .{std.json.fmt(pane_id, .{})});
            },
            .split => |split| {
                try writer.print(
                    "{{\"kind\":\"split\",\"id\":{f},\"axis\":{f},\"first\":",
                    .{ std.json.fmt(split.id, .{}), std.json.fmt(split.axis.label(), .{}) },
                );
                try split.first.writeJson(writer);
                try writer.writeAll(",\"second\":");
                try split.second.writeJson(writer);
                try writer.writeByte('}');
            },
        }
    }
};

pub const AlertState = struct {
    activity: bool = false,
    bell: bool = false,
    silence: bool = false,
    exited: bool = false,
    last_activity_ms: i64 = 0,
    last_bell_ms: i64 = 0,
};

pub const Pane = struct {
    id: []u8,
    window_id: []u8,
    session_id: []u8,
    index: usize,
    title: []u8,
    has_custom_title: bool = false,
    spawn: SpawnSpec,
    native: *NativeSession,
    alerts: AlertState = .{},

    pub fn deinit(self: *Pane, allocator: Allocator) void {
        self.native.event_sink = null;
        self.native.destroy();
        self.spawn.deinit(allocator);
        allocator.free(self.id);
        allocator.free(self.window_id);
        allocator.free(self.session_id);
        allocator.free(self.title);
        allocator.destroy(self);
    }
};

pub const Window = struct {
    id: []u8,
    session_id: []u8,
    index: usize,
    name: []u8,
    active_pane_id: []u8,
    panes: std.ArrayList(*Pane) = .empty,
    layout: *LayoutNode,

    pub fn deinit(self: *Window, allocator: Allocator) void {
        for (self.panes.items) |pane| pane.deinit(allocator);
        self.panes.deinit(allocator);
        self.layout.deinit(allocator);
        allocator.destroy(self.layout);
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.name);
        allocator.free(self.active_pane_id);
        allocator.destroy(self);
    }
};

pub const Session = struct {
    id: []u8,
    name: []u8,
    active_window_id: []u8,
    windows: std.ArrayList(*Window) = .empty,
    next_window_index: usize = 0,
    next_pane_index: usize = 0,

    pub fn deinit(self: *Session, allocator: Allocator) void {
        for (self.windows.items) |window| window.deinit(allocator);
        self.windows.deinit(allocator);
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.active_window_id);
        allocator.destroy(self);
    }
};

pub const Client = struct {
    id: []u8,
    session_id: []u8,
    window_id: []u8,
    pane_id: []u8,
    rows: u16,
    cols: u16,
    active: bool = true,

    pub fn deinit(self: *Client, allocator: Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.window_id);
        allocator.free(self.pane_id);
        allocator.destroy(self);
    }
};

pub const KeyBinding = struct {
    table: []u8,
    key: []u8,
    command: []u8,
    repeat: bool = false,

    pub fn deinit(self: *KeyBinding, allocator: Allocator) void {
        allocator.free(self.table);
        allocator.free(self.key);
        allocator.free(self.command);
    }
};

pub const Manager = struct {
    allocator: Allocator,
    event_sink: ?native_mod.EventSink = null,
    mutex: std.Thread.Mutex = .{},
    sessions: std.ArrayList(*Session) = .empty,
    clients: std.ArrayList(*Client) = .empty,
    key_bindings: std.ArrayList(KeyBinding) = .empty,
    next_session_id: usize = 0,
    next_window_id: usize = 0,
    next_pane_id: usize = 0,
    next_split_id: usize = 0,
    next_client_id: usize = 0,

    pub fn init(allocator: Allocator, event_sink: ?native_mod.EventSink) Manager {
        return .{ .allocator = allocator, .event_sink = event_sink };
    }

    pub fn deinit(self: *Manager) void {
        self.terminateAll();
        for (self.clients.items) |client| client.deinit(self.allocator);
        self.clients.deinit(self.allocator);
        for (self.key_bindings.items) |*binding| binding.deinit(self.allocator);
        self.key_bindings.deinit(self.allocator);
    }

    pub fn count(self: *Manager) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var total: usize = 0;
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| total += window.panes.items.len;
        }
        return total;
    }

    pub fn create(self: *Manager, opts: CreateOptions) !*NativeSession {
        const pane = try self.createSessionPane(opts);
        return pane.native;
    }

    pub fn createSessionPane(self: *Manager, opts: CreateOptions) !*Pane {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session_id = try self.nextIdLocked("sess", &self.next_session_id);
        errdefer self.allocator.free(session_id);
        const window_id = try self.nextIdLocked("win", &self.next_window_id);
        defer self.allocator.free(window_id);
        const pane_id = try self.nextIdLocked("pane", &self.next_pane_id);
        defer self.allocator.free(pane_id);

        const session_name = try self.allocator.dupe(u8, opts.title orelse session_id);
        errdefer self.allocator.free(session_name);
        const window_name = try self.allocator.dupe(u8, opts.title orelse "1");
        errdefer self.allocator.free(window_name);

        var session = try self.allocator.create(Session);
        errdefer self.allocator.destroy(session);
        session.* = .{
            .id = session_id,
            .name = session_name,
            .active_window_id = try self.allocator.dupe(u8, window_id),
        };
        errdefer self.allocator.free(session.active_window_id);

        var window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(window);
        window.* = .{
            .id = try self.allocator.dupe(u8, window_id),
            .session_id = try self.allocator.dupe(u8, session_id),
            .index = 0,
            .name = window_name,
            .active_pane_id = try self.allocator.dupe(u8, pane_id),
            .layout = try LayoutNode.leafNode(self.allocator, pane_id),
        };
        errdefer {
            window.layout.deinit(self.allocator);
            self.allocator.destroy(window.layout);
            self.allocator.free(window.id);
            self.allocator.free(window.session_id);
            self.allocator.free(window.active_pane_id);
        }

        const pane = try self.createPaneLocked(session, window, pane_id, opts);
        errdefer pane.deinit(self.allocator);
        try window.panes.append(self.allocator, pane);
        try session.windows.append(self.allocator, window);
        try self.sessions.append(self.allocator, session);
        return pane;
    }

    pub fn newWindow(self: *Manager, session_id: []const u8, opts: CreateOptions) !*Pane {
        self.mutex.lock();
        defer self.mutex.unlock();

        const session = self.findSessionLocked(session_id) orelse return error.SessionNotFound;
        const window_id = try self.nextIdLocked("win", &self.next_window_id);
        defer self.allocator.free(window_id);
        const pane_id = try self.nextIdLocked("pane", &self.next_pane_id);
        defer self.allocator.free(pane_id);

        const window_name = try self.allocator.dupe(u8, opts.title orelse "window");
        errdefer self.allocator.free(window_name);

        const window = try self.allocator.create(Window);
        errdefer self.allocator.destroy(window);
        window.* = .{
            .id = try self.allocator.dupe(u8, window_id),
            .session_id = try self.allocator.dupe(u8, session.id),
            .index = session.next_window_index + 1,
            .name = window_name,
            .active_pane_id = try self.allocator.dupe(u8, pane_id),
            .layout = try LayoutNode.leafNode(self.allocator, pane_id),
        };
        errdefer {
            window.layout.deinit(self.allocator);
            self.allocator.destroy(window.layout);
            self.allocator.free(window.id);
            self.allocator.free(window.session_id);
            self.allocator.free(window.active_pane_id);
        }

        const pane = try self.createPaneLocked(session, window, pane_id, opts);
        errdefer pane.deinit(self.allocator);
        try window.panes.append(self.allocator, pane);
        try session.windows.append(self.allocator, window);

        session.next_window_index += 1;
        try replaceOwnedString(self.allocator, &session.active_window_id, window.id);
        return pane;
    }

    pub fn splitPane(self: *Manager, target_pane_id: []const u8, axis: Axis, opts: CreateOptions) !*Pane {
        self.mutex.lock();
        defer self.mutex.unlock();

        const found = self.findPaneWithParentsLocked(target_pane_id) orelse return error.PaneNotFound;
        const pane_id = try self.nextIdLocked("pane", &self.next_pane_id);
        defer self.allocator.free(pane_id);
        const split_id = try self.nextIdLocked("split", &self.next_split_id);
        defer self.allocator.free(split_id);

        const pane = try self.createPaneLocked(found.session, found.window, pane_id, opts);
        errdefer pane.deinit(self.allocator);
        if (!try found.window.layout.replaceLeafWithSplit(self.allocator, target_pane_id, axis, pane.id, split_id)) {
            return error.LayoutTargetMissing;
        }
        try found.window.panes.append(self.allocator, pane);
        try replaceOwnedString(self.allocator, &found.window.active_pane_id, pane.id);
        return pane;
    }

    pub fn selectPane(self: *Manager, pane_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const found = self.findPaneWithParentsLocked(pane_id) orelse return error.PaneNotFound;
        try replaceOwnedString(self.allocator, &found.window.active_pane_id, found.pane.id);
        try replaceOwnedString(self.allocator, &found.session.active_window_id, found.window.id);
    }

    pub fn selectWindow(self: *Manager, window_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const found = self.findWindowWithParentLocked(window_id) orelse return error.WindowNotFound;
        try replaceOwnedString(self.allocator, &found.session.active_window_id, found.window.id);
    }

    pub fn renameSession(self: *Manager, session_id: []const u8, title: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const session = self.findSessionLocked(session_id) orelse return error.SessionNotFound;
        try replaceOwnedString(self.allocator, &session.name, title);
    }

    pub fn renameWindow(self: *Manager, window_id: []const u8, title: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const found = self.findWindowWithParentLocked(window_id) orelse return error.WindowNotFound;
        try replaceOwnedString(self.allocator, &found.window.name, title);
    }

    pub fn renamePane(self: *Manager, pane_id: []const u8, title: []const u8, custom: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const pane = self.findPaneLocked(pane_id) orelse return error.PaneNotFound;
        try replaceOwnedString(self.allocator, &pane.title, title);
        pane.has_custom_title = custom;
    }

    pub fn respawnPane(self: *Manager, pane_id: []const u8) !*NativeSession {
        self.mutex.lock();
        defer self.mutex.unlock();

        const pane = self.findPaneLocked(pane_id) orelse return error.PaneNotFound;
        pane.native.event_sink = null;
        pane.native.terminate();
        pane.native.destroy();
        pane.native = try NativeSession.create(self.allocator, pane.spawn.nativeOptions(pane.id, self.event_sink));
        pane.alerts.exited = false;
        pane.native.retain();
        return pane.native;
    }

    pub fn attachClient(self: *Manager, target_pane_id: []const u8, rows: u16, cols: u16) !*Client {
        self.mutex.lock();
        defer self.mutex.unlock();

        const found = self.findPaneWithParentsLocked(target_pane_id) orelse return error.PaneNotFound;
        const client_id = try self.nextIdLocked("client", &self.next_client_id);
        errdefer self.allocator.free(client_id);

        const client = try self.allocator.create(Client);
        errdefer self.allocator.destroy(client);
        client.* = .{
            .id = client_id,
            .session_id = try self.allocator.dupe(u8, found.session.id),
            .window_id = try self.allocator.dupe(u8, found.window.id),
            .pane_id = try self.allocator.dupe(u8, found.pane.id),
            .rows = rows,
            .cols = cols,
        };
        try self.clients.append(self.allocator, client);
        return client;
    }

    pub fn paneScrollbackSnapshot(self: *Manager, allocator: Allocator, pane_id: []const u8) ![]u8 {
        self.mutex.lock();
        const pane = self.findPaneLocked(pane_id) orelse {
            self.mutex.unlock();
            return error.PaneNotFound;
        };
        const native = pane.native;
        native.retain();
        self.mutex.unlock();
        defer native.release();
        return native.scrollbackSnapshot(allocator);
    }

    pub fn detachClient(self: *Manager, client_id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.clients.items, 0..) |client, index| {
            if (std.mem.eql(u8, client.id, client_id)) {
                const removed = self.clients.swapRemove(index);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    pub fn switchClient(self: *Manager, client_id: []const u8, pane_id: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const client = self.findClientLocked(client_id) orelse return error.ClientNotFound;
        const found = self.findPaneWithParentsLocked(pane_id) orelse return error.PaneNotFound;
        try replaceOwnedString(self.allocator, &client.session_id, found.session.id);
        try replaceOwnedString(self.allocator, &client.window_id, found.window.id);
        try replaceOwnedString(self.allocator, &client.pane_id, found.pane.id);
    }

    pub fn bindKey(self: *Manager, table: []const u8, key: []const u8, command: []const u8, repeat: bool) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.key_bindings.items) |*binding| {
            if (std.mem.eql(u8, binding.table, table) and std.mem.eql(u8, binding.key, key)) {
                self.allocator.free(binding.command);
                binding.command = try self.allocator.dupe(u8, command);
                binding.repeat = repeat;
                return;
            }
        }

        try self.key_bindings.append(self.allocator, .{
            .table = try self.allocator.dupe(u8, table),
            .key = try self.allocator.dupe(u8, key),
            .command = try self.allocator.dupe(u8, command),
            .repeat = repeat,
        });
    }

    pub fn executeBinding(self: *Manager, table: []const u8, key: []const u8, target_pane_id: []const u8) !?[]u8 {
        const command = blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.key_bindings.items) |binding| {
                if (std.mem.eql(u8, binding.table, table) and std.mem.eql(u8, binding.key, key)) {
                    break :blk try self.allocator.dupe(u8, binding.command);
                }
            }
            break :blk null;
        } orelse return null;
        errdefer self.allocator.free(command);
        try self.executeCommandLine(command, target_pane_id);
        return command;
    }

    pub fn executeCommandLine(self: *Manager, line: []const u8, target_pane_id: []const u8) !void {
        var iter = std.mem.tokenizeScalar(u8, line, ' ');
        const command = iter.next() orelse return;
        if (std.mem.eql(u8, command, "split-window") or std.mem.eql(u8, command, "splitw")) {
            var axis: Axis = .vertical;
            while (iter.next()) |token| {
                if (std.mem.eql(u8, token, "-h")) axis = .horizontal;
                if (std.mem.eql(u8, token, "-v")) axis = .vertical;
            }
            _ = try self.splitPane(target_pane_id, axis, .{});
            return;
        }
        if (std.mem.eql(u8, command, "new-window") or std.mem.eql(u8, command, "neww")) {
            const found = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                const found = self.findPaneWithParentsLocked(target_pane_id) orelse return error.PaneNotFound;
                break :blk try self.allocator.dupe(u8, found.session.id);
            };
            defer self.allocator.free(found);
            _ = try self.newWindow(found, .{});
            return;
        }
        if (std.mem.eql(u8, command, "respawn-pane") or std.mem.eql(u8, command, "respawnp")) {
            const native = try self.respawnPane(target_pane_id);
            native.release();
            return;
        }
        return error.UnsupportedCommand;
    }

    pub fn markActivity(self: *Manager, pane_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findPaneLocked(pane_id)) |pane| {
            pane.alerts.activity = true;
            pane.alerts.last_activity_ms = std.time.milliTimestamp();
        }
    }

    pub fn markBell(self: *Manager, pane_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findPaneLocked(pane_id)) |pane| {
            pane.alerts.bell = true;
            pane.alerts.last_bell_ms = std.time.milliTimestamp();
        }
    }

    pub fn markExited(self: *Manager, pane_id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.findPaneLocked(pane_id)) |pane| {
            pane.alerts.exited = true;
        }
    }

    pub fn find(self: *Manager, id: []const u8) ?*NativeSession {
        self.mutex.lock();
        defer self.mutex.unlock();
        const pane = self.findPaneLocked(id) orelse return null;
        pane.native.retain();
        return pane.native;
    }

    pub fn terminate(self: *Manager, id: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const found = self.findPaneWithParentsLocked(id) orelse return false;
        if (found.window.panes.items.len == 1 and found.session.windows.items.len == 1) {
            return self.removeSessionLocked(found.session.id);
        }
        return self.removePaneLocked(found.session, found.window, id);
    }

    pub fn terminateAll(self: *Manager) void {
        self.mutex.lock();
        var sessions = self.sessions;
        self.sessions = .empty;
        self.mutex.unlock();

        for (sessions.items) |session| session.deinit(self.allocator);
        sessions.deinit(self.allocator);
    }

    pub fn listJson(self: *Manager, allocator: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeByte('[');
        var first = true;
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (!first) try out.writer.writeByte(',');
                    first = false;
                    const info = try pane.native.infoJson(allocator);
                    defer allocator.free(info);
                    try out.writer.writeAll(info[0 .. info.len - 1]);
                    try out.writer.print(
                        ",\"sessionId\":{f},\"windowId\":{f},\"paneId\":{f}}}",
                        .{ std.json.fmt(session.id, .{}), std.json.fmt(window.id, .{}), std.json.fmt(pane.id, .{}) },
                    );
                }
            }
        }
        try out.writer.writeByte(']');
        return out.toOwnedSlice();
    }

    pub fn snapshotJson(self: *Manager, allocator: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.writeAll("{\"sessions\":[");
        for (self.sessions.items, 0..) |session, index| {
            if (index > 0) try out.writer.writeByte(',');
            try self.writeSessionJsonLocked(&out.writer, session);
        }
        try out.writer.writeAll("],\"clients\":");
        try self.writeClientsJsonLocked(&out.writer);
        try out.writer.writeAll(",\"keyBindings\":");
        try self.writeKeyBindingsJsonLocked(&out.writer);
        try out.writer.writeByte('}');
        return out.toOwnedSlice();
    }

    pub fn clientsJson(self: *Manager, allocator: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try self.writeClientsJsonLocked(&out.writer);
        return out.toOwnedSlice();
    }

    pub fn keysJson(self: *Manager, allocator: Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try self.writeKeyBindingsJsonLocked(&out.writer);
        return out.toOwnedSlice();
    }

    fn createPaneLocked(self: *Manager, session: *Session, window: *Window, pane_id: []const u8, opts: CreateOptions) !*Pane {
        var spawn = try SpawnSpec.fromOptions(self.allocator, opts);
        errdefer spawn.deinit(self.allocator);

        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);
        const title = try self.allocator.dupe(u8, opts.title orelse pane_id);
        errdefer self.allocator.free(title);
        const native = try NativeSession.create(self.allocator, spawn.nativeOptions(pane_id, self.event_sink));
        errdefer native.destroy();

        pane.* = .{
            .id = try self.allocator.dupe(u8, pane_id),
            .window_id = try self.allocator.dupe(u8, window.id),
            .session_id = try self.allocator.dupe(u8, session.id),
            .index = session.next_pane_index,
            .title = title,
            .spawn = spawn,
            .native = native,
        };
        session.next_pane_index += 1;
        return pane;
    }

    fn nextIdLocked(self: *Manager, prefix: []const u8, next: *usize) ![]u8 {
        next.* += 1;
        return std.fmt.allocPrint(self.allocator, "{s}-{d}-{x}", .{ prefix, next.*, std.time.nanoTimestamp() });
    }

    fn findSessionLocked(self: *Manager, id: []const u8) ?*Session {
        for (self.sessions.items) |session| {
            if (std.mem.eql(u8, session.id, id) or std.mem.eql(u8, session.name, id)) return session;
        }
        return null;
    }

    fn findWindowWithParentLocked(self: *Manager, id: []const u8) ?struct { session: *Session, window: *Window } {
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                if (std.mem.eql(u8, window.id, id) or std.mem.eql(u8, window.name, id)) {
                    return .{ .session = session, .window = window };
                }
            }
        }
        return null;
    }

    fn findPaneWithParentsLocked(self: *Manager, id: []const u8) ?struct { session: *Session, window: *Window, pane: *Pane } {
        for (self.sessions.items) |session| {
            for (session.windows.items) |window| {
                for (window.panes.items) |pane| {
                    if (std.mem.eql(u8, pane.id, id)) {
                        return .{ .session = session, .window = window, .pane = pane };
                    }
                }
            }
        }
        return null;
    }

    fn findPaneLocked(self: *Manager, id: []const u8) ?*Pane {
        const found = self.findPaneWithParentsLocked(id) orelse return null;
        return found.pane;
    }

    fn findClientLocked(self: *Manager, id: []const u8) ?*Client {
        for (self.clients.items) |client| {
            if (std.mem.eql(u8, client.id, id)) return client;
        }
        return null;
    }

    fn removeSessionLocked(self: *Manager, id: []const u8) bool {
        for (self.sessions.items, 0..) |session, index| {
            if (std.mem.eql(u8, session.id, id)) {
                const removed = self.sessions.swapRemove(index);
                removed.deinit(self.allocator);
                return true;
            }
        }
        return false;
    }

    fn removePaneLocked(self: *Manager, session: *Session, window: *Window, pane_id: []const u8) bool {
        for (window.panes.items, 0..) |pane, index| {
            if (std.mem.eql(u8, pane.id, pane_id)) {
                const removed = window.panes.swapRemove(index);
                _ = window.layout.removeLeaf(self.allocator, pane_id);
                removed.deinit(self.allocator);
                if (std.mem.eql(u8, window.active_pane_id, pane_id) and window.panes.items.len > 0) {
                    replaceOwnedString(self.allocator, &window.active_pane_id, window.panes.items[0].id) catch {};
                }
                if (window.panes.items.len == 0 and session.windows.items.len > 1) {
                    _ = self.removeWindowLocked(session, window.id);
                }
                return true;
            }
        }
        return false;
    }

    fn removeWindowLocked(self: *Manager, session: *Session, window_id: []const u8) bool {
        for (session.windows.items, 0..) |window, index| {
            if (std.mem.eql(u8, window.id, window_id)) {
                const removed = session.windows.swapRemove(index);
                removed.deinit(self.allocator);
                if (std.mem.eql(u8, session.active_window_id, window_id) and session.windows.items.len > 0) {
                    replaceOwnedString(self.allocator, &session.active_window_id, session.windows.items[0].id) catch {};
                }
                return true;
            }
        }
        return false;
    }

    fn writeSessionJsonLocked(self: *Manager, writer: *std.Io.Writer, session: *Session) !void {
        try writer.print(
            "{{\"id\":{f},\"name\":{f},\"activeWindowId\":{f},\"windows\":[",
            .{ std.json.fmt(session.id, .{}), std.json.fmt(session.name, .{}), std.json.fmt(session.active_window_id, .{}) },
        );
        for (session.windows.items, 0..) |window, index| {
            if (index > 0) try writer.writeByte(',');
            try self.writeWindowJsonLocked(writer, window);
        }
        try writer.writeAll("]}");
    }

    fn writeWindowJsonLocked(self: *Manager, writer: *std.Io.Writer, window: *Window) !void {
        _ = self;
        try writer.print(
            "{{\"id\":{f},\"sessionId\":{f},\"index\":{},\"name\":{f},\"activePaneId\":{f},\"layout\":",
            .{
                std.json.fmt(window.id, .{}),
                std.json.fmt(window.session_id, .{}),
                window.index,
                std.json.fmt(window.name, .{}),
                std.json.fmt(window.active_pane_id, .{}),
            },
        );
        try window.layout.writeJson(writer);
        try writer.writeAll(",\"panes\":[");
        for (window.panes.items, 0..) |pane, index| {
            if (index > 0) try writer.writeByte(',');
            try writePaneJson(writer, pane);
        }
        try writer.writeAll("]}");
    }

    fn writeClientsJsonLocked(self: *Manager, writer: *std.Io.Writer) !void {
        try writer.writeByte('[');
        for (self.clients.items, 0..) |client, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print(
                "{{\"id\":{f},\"sessionId\":{f},\"windowId\":{f},\"paneId\":{f},\"rows\":{},\"cols\":{},\"active\":{}}}",
                .{
                    std.json.fmt(client.id, .{}),
                    std.json.fmt(client.session_id, .{}),
                    std.json.fmt(client.window_id, .{}),
                    std.json.fmt(client.pane_id, .{}),
                    client.rows,
                    client.cols,
                    client.active,
                },
            );
        }
        try writer.writeByte(']');
    }

    fn writeKeyBindingsJsonLocked(self: *Manager, writer: *std.Io.Writer) !void {
        try writer.writeByte('[');
        for (self.key_bindings.items, 0..) |binding, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.print(
                "{{\"table\":{f},\"key\":{f},\"command\":{f},\"repeat\":{}}}",
                .{ std.json.fmt(binding.table, .{}), std.json.fmt(binding.key, .{}), std.json.fmt(binding.command, .{}), binding.repeat },
            );
        }
        try writer.writeByte(']');
    }
};

fn writePaneJson(writer: *std.Io.Writer, pane: *const Pane) !void {
    try writer.print(
        "{{\"id\":{f},\"windowId\":{f},\"sessionId\":{f},\"index\":{},\"title\":{f},\"hasCustomTitle\":{},\"state\":{f},\"pid\":{},\"cwd\":",
        .{
            std.json.fmt(pane.id, .{}),
            std.json.fmt(pane.window_id, .{}),
            std.json.fmt(pane.session_id, .{}),
            pane.index,
            std.json.fmt(pane.title, .{}),
            pane.has_custom_title,
            std.json.fmt(pane.native.state().label(), .{}),
            pane.native.handle.child_pid,
        },
    );
    if (pane.spawn.cwd) |cwd| try writer.print("{f}", .{std.json.fmt(cwd, .{})}) else try writer.writeAll("null");
    try writer.print(
        ",\"command\":{f},\"alerts\":{{\"activity\":{},\"bell\":{},\"silence\":{},\"exited\":{},\"lastActivityMs\":{},\"lastBellMs\":{}}}}}",
        .{
            std.json.fmt(pane.spawn.command orelse "", .{}),
            pane.alerts.activity,
            pane.alerts.bell,
            pane.alerts.silence,
            pane.alerts.exited,
            pane.alerts.last_activity_ms,
            pane.alerts.last_bell_ms,
        },
    );
}

fn dupeOpt(allocator: Allocator, value: ?[]const u8) !?[]u8 {
    return if (value) |text| try allocator.dupe(u8, text) else null;
}

fn dupeStringSlice(allocator: Allocator, entries: []const []const u8) ![][]const u8 {
    const copy = try allocator.alloc([]const u8, entries.len);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |entry| allocator.free(entry);
        allocator.free(copy);
    }
    for (entries, 0..) |entry, index| {
        copy[index] = try allocator.dupe(u8, entry);
        filled += 1;
    }
    return copy;
}

fn freeStringSlice(allocator: Allocator, entries: []const []const u8) void {
    for (entries) |entry| allocator.free(entry);
    allocator.free(entries);
}

fn replaceOwnedString(allocator: Allocator, slot: *[]u8, value: []const u8) !void {
    const replacement = try allocator.dupe(u8, value);
    allocator.free(slot.*);
    slot.* = replacement;
}

test "mux manager creates session window and pane state" {
    var manager = Manager.init(std.testing.allocator, null);
    defer manager.deinit();

    const pane = try manager.createSessionPane(.{ .title = "one", .shell = "/bin/sh", .command = "true" });
    try std.testing.expect(std.mem.startsWith(u8, pane.session_id, "sess-"));
    try std.testing.expect(std.mem.startsWith(u8, pane.window_id, "win-"));
    try std.testing.expect(std.mem.startsWith(u8, pane.id, "pane-"));

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"windows\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"panes\"") != null);
}

test "mux manager splits panes and records layout" {
    var manager = Manager.init(std.testing.allocator, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "true" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);
    const second = try manager.splitPane(first_id, .horizontal, .{ .shell = "/bin/sh", .command = "true" });
    try std.testing.expect(!std.mem.eql(u8, first_id, second.id));

    const snapshot = try manager.snapshotJson(std.testing.allocator);
    defer std.testing.allocator.free(snapshot);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"kind\":\"split\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, snapshot, "\"axis\":\"horizontal\"") != null);
}

test "mux key binding executes tmux-like split command" {
    var manager = Manager.init(std.testing.allocator, null);
    defer manager.deinit();

    const first = try manager.createSessionPane(.{ .shell = "/bin/sh", .command = "true" });
    const first_id = try std.testing.allocator.dupe(u8, first.id);
    defer std.testing.allocator.free(first_id);
    try manager.bindKey("prefix", "%", "split-window -h", false);
    const command = try manager.executeBinding("prefix", "%", first_id);
    defer if (command) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(command != null);
    try std.testing.expectEqual(@as(usize, 2), manager.count());
}
