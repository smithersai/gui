const std = @import("std");

const buffer = @import("buffer.zig");
const foreground = @import("foreground.zig");
const pty = @import("pty.zig");
const protocol = @import("protocol.zig");

pub const NativeSessionState = enum {
    creating,
    running,
    terminated,

    pub fn label(self: NativeSessionState) []const u8 {
        return @tagName(self);
    }

    pub fn canTransition(self: NativeSessionState, next: NativeSessionState) bool {
        return switch (self) {
            .creating => next == .running or next == .terminated,
            .running => next == .terminated,
            .terminated => false,
        };
    }
};

pub const NativeSessionOptions = struct {
    id: []const u8,
    title: ?[]const u8 = null,
    shell: ?[]const u8 = null,
    command: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    rows: u16 = 24,
    cols: u16 = 80,
    scrollback_bytes: usize = buffer.default_capacity,
    event_sink: ?EventSink = null,
};

pub const Event = union(enum) {
    foreground_changed: protocol.ForegroundChangedParams,
    session_exited: protocol.SessionExitedParams,
    pane_output: PaneOutputEvent,
    pane_activity: PaneActivityEvent,
    pane_bell: PaneBellEvent,
};

pub const PaneOutputEvent = struct {
    pane_id: []const u8,
    data: []const u8,
};

pub const PaneActivityEvent = struct {
    pane_id: []const u8,
    last_activity_ms: i64,
};

pub const PaneBellEvent = struct {
    pane_id: []const u8,
    last_bell_ms: i64,
};

pub const EventSink = struct {
    context: *anyopaque,
    emit: *const fn (context: *anyopaque, event: Event) void,
};

pub const NativeSession = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    id: []u8,
    title_value: []u8,
    shell_value: ?[]u8,
    cwd_value: ?[]u8,
    handle: pty.Pty,
    scrollback: buffer.ScrollbackBuffer,
    state_value: NativeSessionState = .creating,
    exit_status: ?u32 = null,
    event_sink: ?EventSink = null,
    foreground_tracker: foreground.Tracker,
    next_foreground_check_ms: i64 = 0,
    reader_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    reader_thread: ?std.Thread = null,

    pub fn create(allocator: std.mem.Allocator, opts: NativeSessionOptions) !*NativeSession {
        const native = try allocator.create(NativeSession);
        errdefer allocator.destroy(native);

        const id = try allocator.dupe(u8, opts.id);
        errdefer allocator.free(id);

        const native_title = try allocator.dupe(u8, opts.title orelse opts.id);
        errdefer allocator.free(native_title);

        const shell = if (opts.shell) |value| try allocator.dupe(u8, value) else null;
        errdefer if (shell) |value| allocator.free(value);

        const cwd = if (opts.cwd) |value| try allocator.dupe(u8, value) else null;
        errdefer if (cwd) |value| allocator.free(value);

        var scrollback = try buffer.ScrollbackBuffer.init(allocator, opts.scrollback_bytes);
        errdefer scrollback.deinit();

        var handle = try pty.Pty.spawn(allocator, .{
            .shell = opts.shell,
            .command = opts.command,
            .cwd = opts.cwd,
            .env = opts.env,
            .rows = opts.rows,
            .cols = opts.cols,
        });
        errdefer handle.close();

        native.* = .{
            .allocator = allocator,
            .id = id,
            .title_value = native_title,
            .shell_value = shell,
            .cwd_value = cwd,
            .handle = handle,
            .scrollback = scrollback,
            .event_sink = opts.event_sink,
            .foreground_tracker = foreground.Tracker.init(handle.child_pid),
            .state_value = .running,
        };
        native.handle.setExitObserver(.{
            .context = native,
            .callback = NativeSession.onPtyExited,
        });

        native.reader_thread = try std.Thread.spawn(.{}, NativeSession.readerLoop, .{native});
        return native;
    }

    pub fn retain(self: *NativeSession) void {
        _ = self.ref_count.fetchAdd(1, .seq_cst);
    }

    pub fn release(self: *NativeSession) void {
        const prev = self.ref_count.fetchSub(1, .seq_cst);
        if (prev == 1) {
            self.destroyInternal();
        }
    }

    pub fn destroy(self: *NativeSession) void {
        self.release();
    }

    fn destroyInternal(self: *NativeSession) void {
        self.reader_stop.store(true, .seq_cst);
        if (self.state() != .terminated) {
            // Use the terminate method which properly waits and reaps
            self.terminate();
        }
        if (self.reader_thread) |thread| thread.join();
        self.handle.close();
        self.scrollback.deinit();
        self.allocator.free(self.id);
        self.allocator.free(self.title_value);
        if (self.shell_value) |value| self.allocator.free(value);
        if (self.cwd_value) |value| self.allocator.free(value);
        self.allocator.destroy(self);
    }

    pub fn state(self: *NativeSession) NativeSessionState {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.state_value;
    }

    pub fn terminate(self: *NativeSession) void {
        self.handle.terminate();

        // Try to reap the child, waiting briefly for it to exit
        var status: ?u32 = null;
        var attempts: usize = 0;
        while (attempts < 20) : (attempts += 1) {
            if (self.handle.reapExited()) |exit_status| {
                status = exit_status;
                break;
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        // If still not exited after 200ms, send SIGKILL
        if (status == null) {
            self.handle.kill();
            // Wait one more time after SIGKILL
            var kill_attempts: usize = 0;
            while (kill_attempts < 10) : (kill_attempts += 1) {
                if (self.handle.reapExited()) |exit_status| {
                    status = exit_status;
                    break;
                }
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }

        self.markTerminated(status);
    }

    pub fn send(self: *NativeSession, text: []const u8, enter: bool) !void {
        try self.handle.write(text);
        if (enter) try self.handle.write("\r");
    }

    pub fn sendKey(self: *NativeSession, key: []const u8) !void {
        const sequence = keySequence(key) orelse return error.UnknownKey;
        try self.handle.write(sequence);
    }

    pub fn resize(self: *NativeSession, cols: u16, rows: u16) !void {
        try self.handle.resize(cols, rows);
    }

    pub fn capture(self: *NativeSession, allocator: std.mem.Allocator, lines: usize) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.scrollback.captureLastLines(allocator, lines);
    }

    pub fn scrollbackSnapshot(self: *NativeSession, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.scrollback.snapshot(allocator);
    }

    pub fn writeInput(self: *NativeSession, bytes: []const u8) !void {
        try self.handle.write(bytes);
    }

    pub fn infoJson(self: *NativeSession, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var out: std.Io.Writer.Allocating = .init(allocator);
        errdefer out.deinit();
        try out.writer.print(
            "{{\"id\":{f},\"title\":{f},\"pid\":{},\"state\":{f},\"cwd\":",
            .{
                std.json.fmt(self.id, .{}),
                std.json.fmt(self.title_value, .{}),
                self.handle.child_pid,
                std.json.fmt(self.state_value.label(), .{}),
            },
        );
        if (self.cwd_value) |cwd| {
            try out.writer.print("{f}", .{std.json.fmt(cwd, .{})});
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeAll(",\"shell\":");
        if (self.shell_value) |shell| {
            try out.writer.print("{f}", .{std.json.fmt(shell, .{})});
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.print(
            ",\"scrollbackBytes\":{},\"exitStatus\":",
            .{self.scrollback.len},
        );
        if (self.exit_status) |status| {
            try out.writer.print("{}", .{status});
        } else {
            try out.writer.writeAll("null");
        }
        try out.writer.writeAll("}");
        return out.toOwnedSlice();
    }

    fn readerLoop(self: *NativeSession) void {
        var read_buf: [8192]u8 = undefined;
        while (!self.reader_stop.load(.seq_cst)) {
            if (self.state() == .terminated) return;
            self.pollForegroundChange() catch {};

            const readable = self.handle.pollReadable(100) catch {
                self.markTerminated(null);
                return;
            };
            if (!readable) {
                if (self.handle.reapExited()) |status| {
                    self.markTerminated(status);
                    return;
                }
                continue;
            }

            const n = self.handle.read(&read_buf) catch {
                self.markTerminated(null);
                return;
            };
            if (n == 0) {
                self.markTerminated(null);
                return;
            }
            self.mutex.lock();
            self.scrollback.append(read_buf[0..n]);
            self.mutex.unlock();
            self.emitEvent(.{ .pane_output = .{
                .pane_id = self.id,
                .data = read_buf[0..n],
            } });
            const now_ms = std.time.milliTimestamp();
            self.emitEvent(.{ .pane_activity = .{
                .pane_id = self.id,
                .last_activity_ms = now_ms,
            } });
            if (std.mem.indexOfScalar(u8, read_buf[0..n], 0x07) != null) {
                self.emitEvent(.{ .pane_bell = .{
                    .pane_id = self.id,
                    .last_bell_ms = now_ms,
                } });
            }
        }
    }

    fn pollForegroundChange(self: *NativeSession) !void {
        const now_ms = std.time.milliTimestamp();
        if (now_ms < self.next_foreground_check_ms) return;
        self.next_foreground_check_ms = now_ms + foreground.poll_interval_ms;

        var process = (try self.foreground_tracker.poll(self.allocator, self.handle.master_fd)) orelse return;
        defer process.deinit();

        self.emitEvent(.{ .foreground_changed = .{
            .session_id = self.id,
            .pid = process.pid,
            .comm = process.comm,
            .argv = process.argv,
        } });
    }

    fn emitEvent(self: *NativeSession, event: Event) void {
        const sink = self.event_sink orelse return;
        sink.emit(sink.context, event);
    }

    fn onPtyExited(context: *anyopaque, pid: std.posix.pid_t, status: u32) void {
        const self: *NativeSession = @ptrCast(@alignCast(context));
        self.emitEvent(.{ .session_exited = .{
            .session_id = self.id,
            .pid = pid,
            .exit_code = if (std.posix.W.IFEXITED(status)) std.posix.W.EXITSTATUS(status) else null,
            .signal = if (std.posix.W.IFSIGNALED(status)) std.posix.W.TERMSIG(status) else null,
        } });
    }

    fn markTerminated(self: *NativeSession, status: ?u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.state_value = .terminated;
        if (self.exit_status == null) self.exit_status = status;
    }
};

fn keySequence(key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, "Enter")) return "\r";
    if (std.mem.eql(u8, key, "Tab")) return "\t";
    if (std.mem.eql(u8, key, "Backspace")) return "\x7f";
    if (std.mem.eql(u8, key, "Escape")) return "\x1b";
    if (std.mem.eql(u8, key, "ArrowUp")) return "\x1b[A";
    if (std.mem.eql(u8, key, "ArrowDown")) return "\x1b[B";
    if (std.mem.eql(u8, key, "ArrowRight")) return "\x1b[C";
    if (std.mem.eql(u8, key, "ArrowLeft")) return "\x1b[D";
    return null;
}

test "native session state machine keeps PTY running until termination" {
    try std.testing.expect(NativeSessionState.creating.canTransition(.running));
    try std.testing.expect(NativeSessionState.running.canTransition(.terminated));
    try std.testing.expect(!NativeSessionState.terminated.canTransition(.running));
}

test "native session key names map to terminal sequences" {
    try std.testing.expectEqualStrings("\x1b[A", keySequence("ArrowUp").?);
    try std.testing.expectEqualStrings("\r", keySequence("Enter").?);
    try std.testing.expect(keySequence("Unknown") == null);
}
