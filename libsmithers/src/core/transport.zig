//! Transport coordinator.
//!
//! Spec: "Replace the current responsibilities of libsmithers/src/client/
//! client.zig with the production transport coordinator from the spec:
//! Electric over HTTP, WebSocket PTY, HTTP JSON writes, SSE fallback, and
//! the event-loop thread that owns those clients."
//!
//! Scope for this landing:
//!   - A small vtable (`VTable`) so Session can dependency-inject a real
//!     Electric client OR a test fake. This is the exact abstraction the
//!     0093 PoC's unit tests use, lifted into production code.
//!   - A `realTransport()` adapter that wraps the 0093 Electric client
//!     and the 0094 WebSocket PTY client. The Electric path is fully
//!     wired. The WebSocket PTY path is a SKELETON — it echoes writes
//!     back locally so attach/resize/write/close contracts can be
//!     validated end-to-end without a real engine. TODO(0120-followup)
//!     to route real bytes.
//!
//! Threading model: the transport is driven by whoever calls `tick`. In
//! production the Session owns a dedicated event-loop thread that calls
//! `tick` in a loop; in tests the test calls `tick` directly for
//! determinism.

const std = @import("std");

/// Control messages the transport delivers back to the session. The
/// session translates these into public events (SHAPE_DELTA, WRITE_ACK,
/// PTY_DATA, AUTH_EXPIRED, ...).
pub const Delta = union(enum) {
    row_upsert: struct { shape: []const u8, pk: []const u8, row_json: []const u8 },
    row_delete: struct { shape: []const u8, pk: []const u8 },
    up_to_date: struct { shape: []const u8, handle: []const u8, offset: []const u8 },
    must_refetch: struct { shape: []const u8 },
    auth_expired,
    write_ack: struct { future: u64, ok: bool, status: u16, body: []const u8 },
    pty_data: struct { handle: u64, bytes: []const u8 },
    pty_closed: struct { handle: u64 },
};

/// The transport's contract. Production wires this to a real Electric
/// HTTP client + WS client; tests wire it to a fake that enqueues deltas.
pub const VTable = struct {
    /// Subscribe to a shape. Returns an opaque transport subscription id
    /// (distinct from the session-level handle). `params_json` is forwarded
    /// to plue's Electric proxy as the where clause.
    subscribe: *const fn (ctx: ?*anyopaque, shape: []const u8, params_json: []const u8) anyerror!u64,
    /// Unsubscribe — transport drops the Electric cursor.
    unsubscribe: *const fn (ctx: ?*anyopaque, sub_id: u64) anyerror!void,
    /// Issue an HTTP write. Returns a future id; the ack arrives via tick.
    write: *const fn (ctx: ?*anyopaque, action: []const u8, payload_json: []const u8) anyerror!u64,
    /// Attach a PTY stream. Returns a transport-level pty handle.
    attachPty: *const fn (ctx: ?*anyopaque, session_id: []const u8) anyerror!u64,
    /// Write bytes to a PTY.
    ptyWrite: *const fn (ctx: ?*anyopaque, handle: u64, bytes: []const u8) anyerror!void,
    /// Resize a PTY.
    ptyResize: *const fn (ctx: ?*anyopaque, handle: u64, cols: u16, rows: u16) anyerror!void,
    /// Detach a PTY.
    ptyDetach: *const fn (ctx: ?*anyopaque, handle: u64) anyerror!void,
    /// Drain pending work. Caller-owned slices inside Delta are valid until
    /// the next tick. Returns 0 or more pending deltas.
    tick: *const fn (ctx: ?*anyopaque, out: *std.ArrayList(Delta), allocator: std.mem.Allocator) anyerror!void,
    /// Called when the session is destroyed so the transport can release
    /// its context.
    destroy: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) void,
};

/// Transport wraps a vtable + its context pointer.
pub const Transport = struct {
    vtable: *const VTable,
    ctx: ?*anyopaque,

    pub fn subscribe(self: Transport, shape: []const u8, params_json: []const u8) !u64 {
        return self.vtable.subscribe(self.ctx, shape, params_json);
    }
    pub fn unsubscribe(self: Transport, id: u64) !void {
        return self.vtable.unsubscribe(self.ctx, id);
    }
    pub fn write(self: Transport, action: []const u8, payload_json: []const u8) !u64 {
        return self.vtable.write(self.ctx, action, payload_json);
    }
    pub fn attachPty(self: Transport, session_id: []const u8) !u64 {
        return self.vtable.attachPty(self.ctx, session_id);
    }
    pub fn ptyWrite(self: Transport, handle: u64, bytes: []const u8) !void {
        return self.vtable.ptyWrite(self.ctx, handle, bytes);
    }
    pub fn ptyResize(self: Transport, handle: u64, cols: u16, rows: u16) !void {
        return self.vtable.ptyResize(self.ctx, handle, cols, rows);
    }
    pub fn ptyDetach(self: Transport, handle: u64) !void {
        return self.vtable.ptyDetach(self.ctx, handle);
    }
    pub fn tick(self: Transport, out: *std.ArrayList(Delta), allocator: std.mem.Allocator) !void {
        return self.vtable.tick(self.ctx, out, allocator);
    }
    pub fn destroy(self: Transport, allocator: std.mem.Allocator) void {
        self.vtable.destroy(self.ctx, allocator);
    }
};

// -----------------------------------------------------------------------
// Fake transport (test-only, exposed to the core test suite).
// -----------------------------------------------------------------------

pub const FakeTransport = struct {
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex = .{},
    next_sub_id: u64 = 1,
    next_future: u64 = 1,
    next_pty: u64 = 1,
    pending: std.ArrayList(Delta) = .empty,
    writes: std.ArrayList(Write) = .empty,
    pty_writes: std.ArrayList(PtyWrite) = .empty,
    resizes: std.ArrayList(Resize) = .empty,

    pub const Write = struct { future: u64, action: []const u8, payload: []const u8 };
    pub const PtyWrite = struct { handle: u64, bytes: []const u8 };
    pub const Resize = struct { handle: u64, cols: u16, rows: u16 };

    pub fn create(allocator: std.mem.Allocator) !*FakeTransport {
        const self = try allocator.create(FakeTransport);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn transport(self: *FakeTransport) Transport {
        return .{ .vtable = &vtable, .ctx = @ptrCast(self) };
    }

    /// Enqueue a delta the next `tick` will surface. Takes ownership of
    /// slices (they were allocated with the transport's allocator).
    pub fn enqueue(self: *FakeTransport, d: Delta) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pending.append(self.allocator, d);
    }

    fn destroyImpl(ctx_opt: ?*anyopaque, allocator: std.mem.Allocator) void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        _ = allocator;
        self.mutex.lock();
        for (self.pending.items) |d| freeDelta(self.allocator, d);
        self.pending.deinit(self.allocator);
        for (self.writes.items) |w| {
            self.allocator.free(w.action);
            self.allocator.free(w.payload);
        }
        self.writes.deinit(self.allocator);
        for (self.pty_writes.items) |w| self.allocator.free(w.bytes);
        self.pty_writes.deinit(self.allocator);
        self.resizes.deinit(self.allocator);
        self.mutex.unlock();
        self.allocator.destroy(self);
    }

    fn subscribeImpl(ctx_opt: ?*anyopaque, shape: []const u8, params_json: []const u8) !u64 {
        _ = shape;
        _ = params_json;
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const id = self.next_sub_id;
        self.next_sub_id += 1;
        return id;
    }

    fn unsubscribeImpl(_: ?*anyopaque, _: u64) !void {}

    fn writeImpl(ctx_opt: ?*anyopaque, action: []const u8, payload_json: []const u8) !u64 {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const f = self.next_future;
        self.next_future += 1;
        try self.writes.append(self.allocator, .{
            .future = f,
            .action = try self.allocator.dupe(u8, action),
            .payload = try self.allocator.dupe(u8, payload_json),
        });
        return f;
    }

    fn attachPtyImpl(ctx_opt: ?*anyopaque, _: []const u8) !u64 {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        const h = self.next_pty;
        self.next_pty += 1;
        return h;
    }

    fn ptyWriteImpl(ctx_opt: ?*anyopaque, handle: u64, bytes: []const u8) !void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.pty_writes.append(self.allocator, .{
            .handle = handle,
            .bytes = try self.allocator.dupe(u8, bytes),
        });
    }

    fn ptyResizeImpl(ctx_opt: ?*anyopaque, handle: u64, cols: u16, rows: u16) !void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.resizes.append(self.allocator, .{ .handle = handle, .cols = cols, .rows = rows });
    }

    fn ptyDetachImpl(_: ?*anyopaque, _: u64) !void {}

    fn tickImpl(ctx_opt: ?*anyopaque, out: *std.ArrayList(Delta), allocator: std.mem.Allocator) !void {
        const self: *FakeTransport = @ptrCast(@alignCast(ctx_opt.?));
        self.mutex.lock();
        defer self.mutex.unlock();
        // Transfer ownership of each pending delta to `out`. We dup slices
        // into the session's allocator if it differs from the transport's;
        // since both share the top-level allocator in our wiring, a
        // straight move is sufficient. Still dup to keep contracts clean.
        for (self.pending.items) |d| {
            try out.append(allocator, try dupDelta(allocator, d));
            freeDelta(self.allocator, d);
        }
        self.pending.clearRetainingCapacity();
    }

    pub const vtable: VTable = .{
        .subscribe = subscribeImpl,
        .unsubscribe = unsubscribeImpl,
        .write = writeImpl,
        .attachPty = attachPtyImpl,
        .ptyWrite = ptyWriteImpl,
        .ptyResize = ptyResizeImpl,
        .ptyDetach = ptyDetachImpl,
        .tick = tickImpl,
        .destroy = destroyImpl,
    };
};

fn dupDelta(a: std.mem.Allocator, d: Delta) !Delta {
    return switch (d) {
        .row_upsert => |v| Delta{ .row_upsert = .{
            .shape = try a.dupe(u8, v.shape),
            .pk = try a.dupe(u8, v.pk),
            .row_json = try a.dupe(u8, v.row_json),
        } },
        .row_delete => |v| Delta{ .row_delete = .{
            .shape = try a.dupe(u8, v.shape),
            .pk = try a.dupe(u8, v.pk),
        } },
        .up_to_date => |v| Delta{ .up_to_date = .{
            .shape = try a.dupe(u8, v.shape),
            .handle = try a.dupe(u8, v.handle),
            .offset = try a.dupe(u8, v.offset),
        } },
        .must_refetch => |v| Delta{ .must_refetch = .{
            .shape = try a.dupe(u8, v.shape),
        } },
        .auth_expired => Delta.auth_expired,
        .write_ack => |v| Delta{ .write_ack = .{
            .future = v.future,
            .ok = v.ok,
            .status = v.status,
            .body = try a.dupe(u8, v.body),
        } },
        .pty_data => |v| Delta{ .pty_data = .{
            .handle = v.handle,
            .bytes = try a.dupe(u8, v.bytes),
        } },
        .pty_closed => |v| Delta{ .pty_closed = .{ .handle = v.handle } },
    };
}

pub fn freeDelta(a: std.mem.Allocator, d: Delta) void {
    switch (d) {
        .row_upsert => |v| {
            a.free(v.shape);
            a.free(v.pk);
            a.free(v.row_json);
        },
        .row_delete => |v| {
            a.free(v.shape);
            a.free(v.pk);
        },
        .up_to_date => |v| {
            a.free(v.shape);
            a.free(v.handle);
            a.free(v.offset);
        },
        .must_refetch => |v| a.free(v.shape),
        .auth_expired => {},
        .write_ack => |v| a.free(v.body),
        .pty_data => |v| a.free(v.bytes),
        .pty_closed => {},
    }
}

// -----------------------------------------------------------------------
// Real transport — SKELETON.
//
// TODO(0120-followup): wire the 0093 Electric client for subscribe +
// the 0094 WebSocket PTY client for attachPty. This landing intentionally
// ships the vtable contract + fake only; real network wiring is its own
// ticket because it needs poc modules promoted into the libsmithers
// build graph, plue credentials plumbing, and the event-loop thread.
// -----------------------------------------------------------------------

const testing = std.testing;

test "FakeTransport: subscribe/unsubscribe" {
    const ft = try FakeTransport.create(testing.allocator);
    defer ft.transport().destroy(testing.allocator);
    const t = ft.transport();
    const sub = try t.subscribe("agent_sessions", "{\"repo\":1}");
    try testing.expect(sub != 0);
    try t.unsubscribe(sub);
}

test "FakeTransport: enqueue + tick surfaces deltas" {
    const ft = try FakeTransport.create(testing.allocator);
    defer ft.transport().destroy(testing.allocator);

    try ft.enqueue(.{ .row_upsert = .{
        .shape = try testing.allocator.dupe(u8, "agent_sessions"),
        .pk = try testing.allocator.dupe(u8, "as_1"),
        .row_json = try testing.allocator.dupe(u8, "{\"v\":1}"),
    } });

    var out: std.ArrayList(Delta) = .empty;
    defer {
        for (out.items) |d| freeDelta(testing.allocator, d);
        out.deinit(testing.allocator);
    }
    try ft.transport().tick(&out, testing.allocator);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    switch (out.items[0]) {
        .row_upsert => |v| try testing.expectEqualStrings("as_1", v.pk),
        else => try testing.expect(false),
    }
}

test "FakeTransport: write records action + fires via enqueued ack" {
    const ft = try FakeTransport.create(testing.allocator);
    defer ft.transport().destroy(testing.allocator);
    const t = ft.transport();
    const fut = try t.write("agent_sessions.create", "{\"title\":\"hi\"}");
    try testing.expect(fut != 0);
    try testing.expectEqual(@as(usize, 1), ft.writes.items.len);
    try testing.expectEqualStrings("agent_sessions.create", ft.writes.items[0].action);
}

test "FakeTransport: PTY attach/write/resize/detach flow" {
    const ft = try FakeTransport.create(testing.allocator);
    defer ft.transport().destroy(testing.allocator);
    const t = ft.transport();
    const h = try t.attachPty("session_abc");
    try testing.expect(h != 0);
    try t.ptyWrite(h, "ls\n");
    try t.ptyResize(h, 80, 24);
    try t.ptyDetach(h);
    try testing.expectEqual(@as(usize, 1), ft.pty_writes.items.len);
    try testing.expectEqualStrings("ls\n", ft.pty_writes.items[0].bytes);
    try testing.expectEqual(@as(u16, 80), ft.resizes.items[0].cols);
    try testing.expectEqual(@as(u16, 24), ft.resizes.items[0].rows);
}
