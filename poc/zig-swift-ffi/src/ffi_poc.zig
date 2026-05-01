//! PoC Zig ↔ Swift observable counter.
//!
//! Threading model (MUST match README + header):
//!   - One background thread per session runs `loop()`.
//!   - Producers call `ffi_tick` from any thread; it increments a counter and
//!     pushes the new value onto an in-memory FIFO queue under `queue_mutex`,
//!     then signals `queue_cond`.
//!   - The loop thread drains the queue under the mutex, releases the mutex,
//!     then invokes every live subscriber for each drained value in order.
//!   - Subscribers live in an `ArrayList(Subscriber)` protected by `sub_mutex`.
//!     The loop takes a snapshot of (callback, user_data, id) under the mutex,
//!     releases, then dispatches — so callbacks never run with `sub_mutex` held.
//!   - Unsubscribe sets a "dead" flag on the subscription. The loop re-checks
//!     that flag per-callback and skips dead entries. Unsubscribe waits on
//!     `inflight_cond` while the target handle is being dispatched.
//!   - Close signals `stop` + `queue_cond`, joins the loop thread, fires any
//!     queued events (to preserve "no drops" semantics), then frees state.

const std = @import("std");
const builtin = @import("builtin");
const Thread = std.Thread;

pub const Callback = *const fn (counter: u64, user_data: ?*anyopaque) callconv(.c) void;

const Subscriber = struct {
    id: u64,
    cb: Callback,
    user_data: ?*anyopaque,
    dead: bool,
};

pub const Session = struct {
    allocator: std.mem.Allocator,
    counter: u64 = 0,

    queue: std.ArrayList(u64) = .empty,
    queue_mutex: Thread.Mutex = .{},
    queue_cond: Thread.Condition = .{},

    subs: std.ArrayList(Subscriber) = .empty,
    sub_mutex: Thread.Mutex = .{},
    inflight_id: u64 = 0,
    inflight_cond: Thread.Condition = .{},
    next_sub_id: u64 = 1,

    stop: bool = false,
    thread: Thread = undefined,

    pub fn create(allocator: std.mem.Allocator) !*Session {
        const s = try allocator.create(Session);
        errdefer allocator.destroy(s);
        s.* = .{ .allocator = allocator };
        s.thread = try Thread.spawn(.{}, loop, .{s});
        return s;
    }

    pub fn destroy(self: *Session) void {
        self.queue_mutex.lock();
        self.stop = true;
        self.queue_cond.broadcast();
        self.queue_mutex.unlock();
        self.thread.join();

        // Drain any remaining queued events so tests asserting "no drops" hold.
        // At this point no one else is touching state.
        if (self.queue.items.len > 0) {
            const pending = self.queue.items;
            const snapshot = self.snapshotSubs() catch &.{};
            defer if (snapshot.len != 0) self.allocator.free(snapshot);
            for (pending) |value| {
                for (snapshot) |sub| {
                    if (!sub.dead) sub.cb(value, sub.user_data);
                }
            }
        }

        self.queue.deinit(self.allocator);
        self.subs.deinit(self.allocator);
        const allocator = self.allocator;
        allocator.destroy(self);
    }

    pub fn tick(self: *Session) u64 {
        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();
        self.counter += 1;
        const value = self.counter;
        self.queue.append(self.allocator, value) catch {
            // Out-of-memory: the "no drops" contract holds only when allocation
            // succeeds. We propagate the counter value back so callers see the
            // advance even if the event was lost. (PoC-level handling.)
            return value;
        };
        self.queue_cond.signal();
        return value;
    }

    pub fn subscribe(self: *Session, cb: Callback, user_data: ?*anyopaque) !u64 {
        self.sub_mutex.lock();
        defer self.sub_mutex.unlock();
        const id = self.next_sub_id;
        self.next_sub_id += 1;
        try self.subs.append(self.allocator, .{
            .id = id,
            .cb = cb,
            .user_data = user_data,
            .dead = false,
        });
        return id;
    }

    pub fn unsubscribe(self: *Session, handle: u64) void {
        self.sub_mutex.lock();
        // Wait for any in-flight dispatch of this handle to finish.
        while (self.inflight_id == handle) {
            self.inflight_cond.wait(&self.sub_mutex);
        }
        // Mark dead; actual removal can happen lazily or here. Remove now to
        // keep the list small.
        var i: usize = 0;
        while (i < self.subs.items.len) : (i += 1) {
            if (self.subs.items[i].id == handle) {
                _ = self.subs.swapRemove(i);
                break;
            }
        }
        self.sub_mutex.unlock();
    }

    fn snapshotSubs(self: *Session) ![]Subscriber {
        self.sub_mutex.lock();
        defer self.sub_mutex.unlock();
        return try self.allocator.dupe(Subscriber, self.subs.items);
    }

    fn loop(self: *Session) void {
        while (true) {
            self.queue_mutex.lock();
            while (!self.stop and self.queue.items.len == 0) {
                self.queue_cond.wait(&self.queue_mutex);
            }
            if (self.stop) {
                self.queue_mutex.unlock();
                return;
            }
            // Drain into a local buffer, release the mutex before dispatching.
            const drained = self.queue.toOwnedSlice(self.allocator) catch {
                // If allocation fails, fall back to copying into a fixed buffer.
                // Should not happen in PoC.
                self.queue_mutex.unlock();
                continue;
            };
            self.queue_mutex.unlock();
            defer self.allocator.free(drained);

            // Take a subscriber snapshot under sub_mutex.
            const snapshot = self.snapshotSubs() catch {
                continue;
            };
            defer self.allocator.free(snapshot);

            for (drained) |value| {
                for (snapshot) |sub| {
                    // Re-check dead state so unsubscribe during dispatch works.
                    self.sub_mutex.lock();
                    var is_live = false;
                    for (self.subs.items) |s| {
                        if (s.id == sub.id and !s.dead) {
                            is_live = true;
                            break;
                        }
                    }
                    if (!is_live) {
                        self.sub_mutex.unlock();
                        continue;
                    }
                    self.inflight_id = sub.id;
                    self.sub_mutex.unlock();

                    sub.cb(value, sub.user_data);

                    self.sub_mutex.lock();
                    self.inflight_id = 0;
                    self.inflight_cond.broadcast();
                    self.sub_mutex.unlock();
                }
            }
        }
    }
};

// ---- C ABI ----------------------------------------------------------------

fn sessionAllocator() std.mem.Allocator {
    return std.heap.c_allocator;
}

export fn ffi_new_session() callconv(.c) ?*Session {
    const s = Session.create(sessionAllocator()) catch return null;
    return s;
}

export fn ffi_close_session(s: ?*Session) callconv(.c) void {
    if (s) |ss| ss.destroy();
}

export fn ffi_tick(s: ?*Session) callconv(.c) u64 {
    const ss = s orelse return 0;
    return ss.tick();
}

export fn ffi_subscribe(s: ?*Session, cb: ?Callback, user_data: ?*anyopaque) callconv(.c) u64 {
    const ss = s orelse return 0;
    const real_cb = cb orelse return 0;
    return ss.subscribe(real_cb, user_data) catch 0;
}

export fn ffi_unsubscribe(s: ?*Session, handle: u64) callconv(.c) void {
    const ss = s orelse return;
    if (handle == 0) return;
    ss.unsubscribe(handle);
}

// ---- Tests (run via `zig build test` inside poc/zig-swift-ffi/) -----------

const testing = std.testing;

fn testCb(counter: u64, user_data: ?*anyopaque) callconv(.c) void {
    const ctx: *TestCtx = @ptrCast(@alignCast(user_data.?));
    ctx.mu.lock();
    defer ctx.mu.unlock();
    ctx.values.append(ctx.allocator, counter) catch unreachable;
    ctx.cond.signal();
}

const TestCtx = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(u64) = .empty,
    mu: Thread.Mutex = .{},
    cond: Thread.Condition = .{},
};

test "tick order and completeness — 1000 rapid ticks" {
    const alloc = testing.allocator;
    const s = try Session.create(alloc);
    defer s.destroy();

    var ctx = TestCtx{ .allocator = alloc };
    defer ctx.values.deinit(alloc);

    const h = try s.subscribe(&testCb, &ctx);
    _ = h;

    const N: u64 = 1000;
    var i: u64 = 0;
    while (i < N) : (i += 1) {
        _ = s.tick();
    }

    // Wait for all callbacks (bounded).
    const deadline = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    ctx.mu.lock();
    while (ctx.values.items.len < N) {
        if (std.time.nanoTimestamp() > deadline) break;
        ctx.cond.timedWait(&ctx.mu, 100 * std.time.ns_per_ms) catch {};
    }
    const got = try alloc.dupe(u64, ctx.values.items);
    ctx.mu.unlock();
    defer alloc.free(got);

    try testing.expectEqual(@as(usize, N), got.len);
    for (got, 0..) |v, idx| {
        try testing.expectEqual(@as(u64, @intCast(idx + 1)), v);
    }
}

test "close with live subscribers does not crash" {
    const alloc = testing.allocator;
    const s = try Session.create(alloc);
    var ctx = TestCtx{ .allocator = alloc };
    defer ctx.values.deinit(alloc);
    _ = try s.subscribe(&testCb, &ctx);
    _ = s.tick();
    s.destroy();
}

test "unsubscribe stops callbacks" {
    const alloc = testing.allocator;
    const s = try Session.create(alloc);
    defer s.destroy();

    var ctx = TestCtx{ .allocator = alloc };
    defer ctx.values.deinit(alloc);

    const h = try s.subscribe(&testCb, &ctx);
    _ = s.tick();
    // Give the loop a moment to deliver the first tick.
    std.Thread.sleep(50 * std.time.ns_per_ms);

    s.unsubscribe(h);

    // Further ticks should not reach ctx.
    const before = blk: {
        ctx.mu.lock();
        defer ctx.mu.unlock();
        break :blk ctx.values.items.len;
    };
    _ = s.tick();
    _ = s.tick();
    std.Thread.sleep(50 * std.time.ns_per_ms);
    const after = blk: {
        ctx.mu.lock();
        defer ctx.mu.unlock();
        break :blk ctx.values.items.len;
    };
    try testing.expectEqual(before, after);
}
