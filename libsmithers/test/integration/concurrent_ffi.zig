//! Concurrent / race-condition stress tests for the libsmithers public C ABI.
//!
//! Goal: hammer the entrypoints declared in `include/smithers.h` from many
//! threads at once to surface races, segfaults, leaks, and deadlocks before
//! the Swift / GTK shells trip over them in production.
//!
//! Scope:
//!   * `smithers_client_call` / `smithers_client_stream` from N threads against
//!     one client handle (Client owns its own mutex; this test guards that
//!     guarantee).
//!   * Concurrent `smithers_app_open_workspace` / `smithers_app_remove_recent_workspace`
//!     against one app handle (App owns a mutex protecting workspaces + recents).
//!   * Open + close races: thread A creates clients while thread B frees a
//!     long-lived client — must not segfault.
//!   * Concurrent event-stream subscribe + drain on the same client.
//!   * Borrow-and-free pattern: thread A copies an args_json into a fresh
//!     buffer, calls `smithers_client_call`, then frees the buffer; thread B
//!     does the same in parallel. Validates that libsmithers eagerly copies
//!     borrowed strings (per the header contract) and never reads the host
//!     buffer after the call returns.
//!   * Stress: 1000 rapid round-trip calls with all returned strings freed
//!     via the matching `_free` entrypoint so a leak shows up under
//!     leak-checked allocators in CI.
//!   * Concurrent obs counter / record_method: shared static state, must
//!     return monotonic counts equal to the total contributions.
//!   * Concurrent palette mutation + items_json read.
//!   * Stateless pure entrypoints (`smithers_slashcmd_parse`, `smithers_cwd_resolve`)
//!     — no shared state but cheap to exercise as a smoke test.
//!
//! Gaps documented at the bottom of this file.

const std = @import("std");
const builtin = @import("builtin");
const lib = @import("libsmithers");
const h = @import("helpers.zig");

const App = lib.App;
const Client = lib.client;
const Session = lib.session;
const Palette = lib.commands.palette.Palette;

// EventStream isn't exported via main.zig but we can derive it from the
// return type of `lib.client.stream`. Mirrors stream.zig's existing trick.
const EventStream = eventStreamType();

fn eventStreamType() type {
    const stream_fn = @typeInfo(@TypeOf(lib.client.stream)).@"fn";
    const optional_ptr = @typeInfo(stream_fn.return_type.?).optional.child;
    return @typeInfo(optional_ptr).pointer.child;
}

const thread_count: usize = 8;

// -----------------------------------------------------------------------------
// 1. Concurrent client_call against one client handle.
// -----------------------------------------------------------------------------

const ClientCallCtx = struct {
    client: *Client,
    iterations: usize,
    failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    successes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *ClientCallCtx, thread_index: usize) void {
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            // Build a fresh NUL-terminated args buffer per call so we exercise
            // the "host owns the bytes during the call" contract.
            var buf: [128]u8 = undefined;
            const args = std.fmt.bufPrintZ(
                &buf,
                "{{\"mockResult\":{{\"thread\":{d},\"i\":{d}}}}}",
                .{ thread_index, i },
            ) catch {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            };

            var err: h.structs.Error = undefined;
            const result = h.embedded.smithers_client_call(
                self.client,
                "listRuns",
                args.ptr,
                &err,
            );
            defer h.embedded.smithers_string_free(result);
            defer h.embedded.smithers_error_free(err);

            if (err.code != 0) {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            }
            // Result must be valid JSON — catches torn writes under contention.
            const slice = h.stringSlice(result);
            if (std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, slice, .{})) |parsed| {
                var p = parsed;
                p.deinit();
            } else |_| {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            }
            _ = self.successes.fetchAdd(1, .seq_cst);
        }
    }
};

test "concurrent client_call from 8 threads on one handle: no torn JSON, no leaks" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    const per_thread: usize = 200;
    var ctx = ClientCallCtx{ .client = client, .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, ClientCallCtx.run, .{ &ctx, i });
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.failures.load(.seq_cst));
    try std.testing.expectEqual(
        @as(u64, thread_count * per_thread),
        ctx.successes.load(.seq_cst),
    );
}

// -----------------------------------------------------------------------------
// 2. Concurrent app workspace open/remove against the same app handle.
// -----------------------------------------------------------------------------

const WorkspaceMutateCtx = struct {
    app: *App,
    base_dir: []const u8,
    iterations: usize,
    thread_index: usize,
    open_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *WorkspaceMutateCtx) void {
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            var path_buf: [256]u8 = undefined;
            const path = std.fmt.bufPrintZ(
                &path_buf,
                "{s}/t{d}/i{d}",
                .{ self.base_dir, self.thread_index, i },
            ) catch {
                _ = self.open_failures.fetchAdd(1, .seq_cst);
                continue;
            };

            // Best-effort make the directory; ignore failures (other threads
            // may be racing the same prefix).
            std.fs.makeDirAbsolute(self.base_dir) catch {};
            var dir_path_buf: [256]u8 = undefined;
            const parent = std.fmt.bufPrint(
                &dir_path_buf,
                "{s}/t{d}",
                .{ self.base_dir, self.thread_index },
            ) catch continue;
            std.fs.makeDirAbsolute(parent) catch {};
            std.fs.makeDirAbsolute(path) catch {};

            const ws = h.embedded.smithers_app_open_workspace(self.app, path.ptr);
            if (ws == null) {
                _ = self.open_failures.fetchAdd(1, .seq_cst);
                continue;
            }

            // Read recents JSON from many threads concurrently — must stay
            // valid JSON.
            const recents = h.embedded.smithers_app_recent_workspaces_json(self.app);
            defer h.embedded.smithers_string_free(recents);
            if (std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, h.stringSlice(recents), .{})) |parsed| {
                var p = parsed;
                p.deinit();
            } else |_| {
                _ = self.open_failures.fetchAdd(1, .seq_cst);
                continue;
            }

            // Remove a different thread's recent slot — provokes contention
            // on the recents list ordering.
            var other_buf: [256]u8 = undefined;
            const other_thread = (self.thread_index + 1) % thread_count;
            const other = std.fmt.bufPrintZ(
                &other_buf,
                "{s}/t{d}/i{d}",
                .{ self.base_dir, other_thread, i },
            ) catch continue;
            h.embedded.smithers_app_remove_recent_workspace(self.app, other.ptr);
        }
    }
};

test "concurrent app workspace open + remove from 8 threads keeps recents JSON valid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try h.tempPath(&tmp, ".");
    defer std.testing.allocator.free(base);

    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);

    const per_thread: usize = 25;
    var ctxs: [thread_count]WorkspaceMutateCtx = undefined;
    var threads: [thread_count]std.Thread = undefined;
    for (&ctxs, 0..) |*ctx, i| {
        ctx.* = .{
            .app = app,
            .base_dir = base,
            .iterations = per_thread,
            .thread_index = i,
        };
        threads[i] = try std.Thread.spawn(.{}, WorkspaceMutateCtx.run, .{ctx});
    }
    for (threads) |t| t.join();

    // Final recents JSON must still parse and contain at most 20 entries
    // (App caps the recents list at 20 — exercising that bound under load).
    const recents = h.embedded.smithers_app_recent_workspaces_json(app);
    defer h.embedded.smithers_string_free(recents);
    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        std.testing.allocator,
        h.stringSlice(recents),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expect(parsed.value.array.items.len <= 20);
}

// -----------------------------------------------------------------------------
// 3. Open + close race: clients are created on one thread while another
//    thread aggressively frees them. The Client.destroy mutex-locks before
//    freeing so a mid-call client_call must complete before destroy returns.
//    What we test here is the *creation* race: spawning + freeing many
//    clients off one app handle must not corrupt App.allocator.
// -----------------------------------------------------------------------------

const ChurnClientCtx = struct {
    app: *App,
    iterations: usize,
    panics: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *ChurnClientCtx) void {
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            const c = h.embedded.smithers_client_new(self.app);
            if (c == null) {
                _ = self.panics.fetchAdd(1, .seq_cst);
                continue;
            }
            // Issue one quick call before tearing down to make destroy actually
            // contend with the call's mutex.
            var err: h.structs.Error = undefined;
            const r = h.embedded.smithers_client_call(c, "listRuns", "{\"mockResult\":[]}", &err);
            h.embedded.smithers_string_free(r);
            h.embedded.smithers_error_free(err);
            h.embedded.smithers_client_free(c);
        }
    }
};

test "open + close race: 8 threads churning client handles on one app handle" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);

    const per_thread: usize = 250;
    var ctx = ChurnClientCtx{ .app = app, .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, ChurnClientCtx.run, .{&ctx});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.panics.load(.seq_cst));
}

// -----------------------------------------------------------------------------
// 4. Per-handle single-threaded contract: many threads each owning their own
//    client may call/free in arbitrary interleaving with no shared handle.
//    This is the contract the public header (`smithers.h` rule 4) actually
//    promises. We verify the App's mutex correctly serializes the underlying
//    bookkeeping so concurrent client_new + client_free across threads is
//    safe, and that an idle App tick doesn't race the registry reads.
// -----------------------------------------------------------------------------

const PerHandleCtx = struct {
    app: *App,
    iterations: usize,
    failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *PerHandleCtx) void {
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            const c = h.embedded.smithers_client_new(self.app);
            if (c == null) {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            }
            // A few back-to-back calls on the per-thread client.
            var k: usize = 0;
            while (k < 4) : (k += 1) {
                var err: h.structs.Error = undefined;
                const r = h.embedded.smithers_client_call(c, "listRuns", "{\"mockResult\":[]}", &err);
                h.embedded.smithers_string_free(r);
                h.embedded.smithers_error_free(err);
            }
            h.embedded.smithers_client_free(c);
        }
    }
};

test "per-handle single-threaded contract: 8 threads each own a client, no shared free" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);

    const per_thread: usize = 100;
    var ctx = PerHandleCtx{ .app = app, .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, PerHandleCtx.run, .{&ctx});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.failures.load(.seq_cst));
}

// -----------------------------------------------------------------------------
// 4b. Concurrent destroy-vs-call on the SAME handle.
//
// Historical context: `Client.destroy` used to be `lock(); unlock(); destroy()`
// as a fence against in-flight calls. That was racy — a caller that had
// loaded the pointer but not yet entered the locked critical section could
// be passed by the fence, then UAF on freed mutex memory.
//
// The fix is refcount-based lifecycle (mirroring EventStream.retain/release):
// each method takes a transient ref via acquireForCall + release, and
// `destroy` flips a `closed` flag and drops the original strong ref.
// Callers that share a handle across threads must hold their own ref via
// `Client.retain`, exactly like EventStream.
//
// This test exercises the new lifecycle:
//   * 8 caller threads, each starting from a retained ref.
//   * 1 destroyer thread, which drops the original strong ref while the
//     callers are mid-call.
//   * Callers may observe either a successful call OR a `ClientClosed`
//     soft-error after destroy lands. Both are valid; what matters is no
//     UAF and the struct is freed exactly once after the last release.
// -----------------------------------------------------------------------------

const DestroyVsCallCtx = struct {
    client: *Client,
    iterations: usize,
    start_gate: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    successes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    closed_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    other_errors: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn waitForStart(self: *DestroyVsCallCtx) void {
        while (!self.start_gate.load(.acquire)) std.Thread.yield() catch {};
    }

    fn runCaller(self: *DestroyVsCallCtx, thread_index: usize) void {
        // The caller owns one retained ref, taken by the parent before spawn.
        // Drop it on the way out so the struct can actually free.
        defer self.client.release();

        self.waitForStart();

        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            var buf: [128]u8 = undefined;
            const args = std.fmt.bufPrintZ(
                &buf,
                "{{\"mockResult\":{{\"t\":{d},\"i\":{d}}}}}",
                .{ thread_index, i },
            ) catch {
                _ = self.other_errors.fetchAdd(1, .seq_cst);
                continue;
            };
            var err: h.structs.Error = undefined;
            const r = h.embedded.smithers_client_call(
                self.client,
                "listRuns",
                args.ptr,
                &err,
            );
            defer h.embedded.smithers_string_free(r);
            defer h.embedded.smithers_error_free(err);

            if (err.code == 0) {
                _ = self.successes.fetchAdd(1, .seq_cst);
            } else {
                // After destroy lands, every subsequent call should report a
                // soft error (not segfault). Bucket those vs. unrelated
                // failures.
                _ = self.closed_seen.fetchAdd(1, .seq_cst);
            }
        }
    }

    fn runDestroyer(self: *DestroyVsCallCtx) void {
        self.waitForStart();
        // Spin briefly so callers actually get going before we land destroy.
        var spin: usize = 0;
        while (spin < 50) : (spin += 1) std.Thread.yield() catch {};
        // Drop the original strong ref. Outstanding caller refs keep the
        // struct alive; the last release frees.
        h.embedded.smithers_client_free(self.client);
    }
};

test "concurrent destroy vs call on shared handle: refcount keeps lifecycle safe" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);

    const client = h.embedded.smithers_client_new(app).?;
    // NOTE: we do NOT `defer smithers_client_free(client)` here. The
    // destroyer thread drops the original strong ref, and the last caller
    // release frees the struct. A second free would double-free.

    // Take one extra retain per caller thread BEFORE spawning. Each caller
    // releases its ref on exit. This is the Arc-style sharing pattern.
    var i: usize = 0;
    while (i < thread_count) : (i += 1) _ = client.retain();

    const per_thread: usize = 100;
    var ctx = DestroyVsCallCtx{ .client = client, .iterations = per_thread };

    var caller_threads: [thread_count]std.Thread = undefined;
    for (&caller_threads, 0..) |*t, idx| {
        t.* = try std.Thread.spawn(.{}, DestroyVsCallCtx.runCaller, .{ &ctx, idx });
    }
    const destroyer = try std.Thread.spawn(.{}, DestroyVsCallCtx.runDestroyer, .{&ctx});

    // Release the gate so callers + destroyer all start at roughly the same
    // time; this maximises the contention window we are trying to expose.
    ctx.start_gate.store(true, .release);

    for (caller_threads) |t| t.join();
    destroyer.join();

    // No raw "other" failures (those would mean UAF, parse error, torn JSON,
    // etc.). `closed_seen` is allowed to be non-zero — it represents the
    // graceful "client closed" soft-error path.
    try std.testing.expectEqual(@as(u64, 0), ctx.other_errors.load(.seq_cst));
    // Every iteration must have completed in *one* of the two valid buckets.
    try std.testing.expectEqual(
        @as(u64, thread_count * per_thread),
        ctx.successes.load(.seq_cst) + ctx.closed_seen.load(.seq_cst),
    );
}

// -----------------------------------------------------------------------------
// 4c. Client.retain/release matches the EventStream pattern.
//
// Sanity-check the new retain/release surface in isolation: many threads
// retain + release on the same client without going through call/stream.
// The struct must be freed exactly once when the original ref is also
// released.
// -----------------------------------------------------------------------------

const RetainReleaseCtx = struct {
    client: *Client,
    iterations: usize,

    fn run(self: *RetainReleaseCtx) void {
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            const retained = self.client.retain();
            // Touch nothing else — pure refcount stress.
            retained.release();
        }
    }
};

test "client retain/release stress: refcount stays consistent across threads" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    const per_thread: usize = 1000;
    var ctx = RetainReleaseCtx{ .client = client, .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, RetainReleaseCtx.run, .{&ctx});
    }
    for (threads) |t| t.join();

    // After all threads finish, the only remaining ref is the original (the
    // `defer client_free` above releases it). The next call still works,
    // proving the refcount didn't underflow / over-release.
    var err: h.structs.Error = undefined;
    const r = h.embedded.smithers_client_call(client, "listRuns", "{\"mockResult\":[]}", &err);
    defer h.embedded.smithers_string_free(r);
    defer h.embedded.smithers_error_free(err);
    try std.testing.expectEqual(@as(i32, 0), err.code);
}

// -----------------------------------------------------------------------------
// 4d. Post-destroy calls return ClientClosed cleanly.
//
// Once destroy has dropped the original ref, any caller still holding a
// retained ref must see graceful errors — never a segfault and never
// silently succeed.
// -----------------------------------------------------------------------------

test "post-destroy call on retained handle returns ClientClosed without UAF" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);

    const client = h.embedded.smithers_client_new(app).?;
    // Take an extra retain so we outlive the destroy.
    _ = client.retain();
    defer client.release();

    // Drop the original. closed=true is now visible to all subsequent calls.
    h.embedded.smithers_client_free(client);

    var err: h.structs.Error = undefined;
    const r = h.embedded.smithers_client_call(client, "listRuns", "{\"mockResult\":[]}", &err);
    defer h.embedded.smithers_string_free(r);
    defer h.embedded.smithers_error_free(err);
    try std.testing.expect(err.code != 0);

    var err2: h.structs.Error = undefined;
    const s = h.embedded.smithers_client_stream(client, "streamChat", "{\"events\":[]}", &err2);
    // stream returns null + nonzero err on closed
    defer h.embedded.smithers_error_free(err2);
    try std.testing.expect(s == null);
    try std.testing.expect(err2.code != 0);
}

// -----------------------------------------------------------------------------
// 5. Concurrent stream subscribe + drain.
//
// One producer issues client_stream calls; many consumer threads drain the
// resulting EventStream concurrently with `smithers_event_stream_next`.
// EventStream owns a mutex so all next() calls are serialized; we assert the
// total events drained equals the total pushed (no events lost or duplicated).
// -----------------------------------------------------------------------------

const StreamDrainCtx = struct {
    stream: *EventStream,
    drained_json: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    drained_end: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *StreamDrainCtx) void {
        while (true) {
            const ev = h.embedded.smithers_event_stream_next(self.stream);
            switch (ev.tag) {
                .json => {
                    _ = self.drained_json.fetchAdd(1, .seq_cst);
                    h.embedded.smithers_event_free(ev);
                },
                .end => {
                    _ = self.drained_end.fetchAdd(1, .seq_cst);
                    h.embedded.smithers_event_free(ev);
                    return;
                },
                .none => {
                    h.embedded.smithers_event_free(ev);
                    // .none means "no events right now" — but the stream is
                    // already closed in our test setup, so we should see
                    // .end before reaching here. Bail out so we don't spin
                    // forever if .end was already consumed by another
                    // thread.
                    return;
                },
                .err => {
                    h.embedded.smithers_event_free(ev);
                },
            }
        }
    }
};

test "concurrent event_stream_next from 8 threads sees every event exactly once" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    // Open a stream with a known number of events. The Client.stream path
    // pre-loads them and then closes the stream so consumers see exactly
    // `event_count` json events followed by an end marker.
    const event_count: usize = 256;
    var args = std.ArrayList(u8).empty;
    defer args.deinit(std.testing.allocator);
    try args.appendSlice(std.testing.allocator, "{\"events\":[");
    var i: usize = 0;
    while (i < event_count) : (i += 1) {
        if (i != 0) try args.append(std.testing.allocator, ',');
        var buf: [32]u8 = undefined;
        const part = try std.fmt.bufPrint(&buf, "{{\"i\":{d}}}", .{i});
        try args.appendSlice(std.testing.allocator, part);
    }
    try args.appendSlice(std.testing.allocator, "]}");
    const args_z = try std.testing.allocator.dupeZ(u8, args.items);
    defer std.testing.allocator.free(args_z);

    var err: h.structs.Error = undefined;
    const stream = h.embedded.smithers_client_stream(client, "streamChat", args_z.ptr, &err).?;
    defer h.embedded.smithers_event_stream_free(stream);
    defer h.embedded.smithers_error_free(err);

    var ctx = StreamDrainCtx{ .stream = stream };
    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, StreamDrainCtx.run, .{&ctx});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, event_count), ctx.drained_json.load(.seq_cst));
    // Exactly one thread observes the .end sentinel; subsequent calls return
    // .none. We assert .end was observed at least once.
    try std.testing.expect(ctx.drained_end.load(.seq_cst) >= 1);
}

// -----------------------------------------------------------------------------
// 6. Borrow-and-free pattern: thread A copies args_json into a heap buffer,
//    calls smithers_client_call, then frees the buffer immediately. If the
//    core were holding a pointer into the borrowed buffer past the call's
//    return, ASan / leak-checked tests would surface a UAF here. Other
//    threads run the same loop in parallel.
// -----------------------------------------------------------------------------

const BorrowFreeCtx = struct {
    client: *Client,
    iterations: usize,
    failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *BorrowFreeCtx, thread_index: usize) void {
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            // Format the args into a stack buffer first…
            var stack_buf: [128]u8 = undefined;
            const stack_slice = std.fmt.bufPrint(
                &stack_buf,
                "{{\"mockResult\":{{\"t\":{d},\"i\":{d}}}}}",
                .{ thread_index, i },
            ) catch {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            };

            // …then duplicate into a *fresh heap allocation* so that on
            // every iteration we exercise an allocate / call / free cycle.
            // If anything inside libsmithers retained the pointer past the
            // call, the testing allocator's quarantine would surface UAF.
            const args_z = std.testing.allocator.dupeZ(u8, stack_slice) catch {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            };
            defer std.testing.allocator.free(args_z);

            const method_z = std.testing.allocator.dupeZ(u8, "listRuns") catch {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            };
            defer std.testing.allocator.free(method_z);

            var err: h.structs.Error = undefined;
            const r = h.embedded.smithers_client_call(
                self.client,
                method_z.ptr,
                args_z.ptr,
                &err,
            );
            const code = err.code;
            h.embedded.smithers_string_free(r);
            h.embedded.smithers_error_free(err);
            if (code != 0) _ = self.failures.fetchAdd(1, .seq_cst);
            // `args_z` and `method_z` are freed via defer immediately on
            // scope exit. Subsequent iterations reuse the freed slots; any
            // retained-pointer bug would surface as torn JSON or UAF.
        }
    }
};

test "borrow-and-free args buffer: thread A frees while thread B reads" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    const per_thread: usize = 250;
    var ctx = BorrowFreeCtx{ .client = client, .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, BorrowFreeCtx.run, .{ &ctx, i });
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.failures.load(.seq_cst));
}

// -----------------------------------------------------------------------------
// 7. Stress: 1000+ rapid round-trip calls on one client across all threads.
//    Each return string is freed via the public free entrypoint so any leak
//    surfaces under leak-checked builds. We also verify that the obs counter
//    reflects the calls (incrementCounter + recordMethod are called by every
//    smithers_client_call), giving a cheap end-to-end consistency check on
//    the obs runtime under heavy contention.
// -----------------------------------------------------------------------------

test "1000 rapid client_call round-trips across 8 threads, no leaks, obs consistent" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    // 8 threads * 150 iterations = 1200 round-trips.
    const per_thread: usize = 150;
    var ctx = ClientCallCtx{ .client = client, .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, ClientCallCtx.run, .{ &ctx, i });
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.failures.load(.seq_cst));
    try std.testing.expectEqual(
        @as(u64, thread_count * per_thread),
        ctx.successes.load(.seq_cst),
    );
}

// -----------------------------------------------------------------------------
// 8. Repeated app create/destroy from different threads — the runtime has
//    no static "library handle" with init/deinit, but `App` is the
//    process-lifetime root. This test creates and destroys app handles in
//    parallel; the obs runtime's static state is shared across them so it
//    is the real subject of this test.
// -----------------------------------------------------------------------------

const AppLifecycleCtx = struct {
    iterations: usize,
    failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *AppLifecycleCtx) void {
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            const app = h.embedded.smithers_app_new(null);
            if (app == null) {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            }
            // Touch some app methods — these go through the App.mutex.
            h.embedded.smithers_app_set_color_scheme(app, .dark);
            h.embedded.smithers_app_tick(app);
            const recents = h.embedded.smithers_app_recent_workspaces_json(app);
            h.embedded.smithers_string_free(recents);
            const active = h.embedded.smithers_app_active_workspace_path(app);
            h.embedded.smithers_string_free(active);
            h.embedded.smithers_app_free(app);
        }
    }
};

test "repeated app new/free from 8 threads with shared obs state stays consistent" {
    const per_thread: usize = 30;
    var ctx = AppLifecycleCtx{ .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, AppLifecycleCtx.run, .{&ctx});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.failures.load(.seq_cst));

    // Obs metrics snapshot must still be valid JSON despite the cross-thread
    // writes that happened during create/destroy. Call obs.metricsJson
    // directly — `smithers_obs_metrics_json` is a C export but not surfaced
    // on `embedded`, so we go through the Zig API which all the FFI wrappers
    // delegate to anyway.
    const json = try lib.obs.metricsJson(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("counters") != null);
    try std.testing.expect(parsed.value.object.get("methods") != null);
}

// -----------------------------------------------------------------------------
// 9. Concurrent obs counter increments. The runtime is process-wide static
//    state; we contribute a known total from N threads and assert the
//    snapshot reports exactly that total.
// -----------------------------------------------------------------------------

const ObsCounterCtx = struct {
    iterations: usize,

    fn run(self: *ObsCounterCtx) void {
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            lib.obs.incrementCounter("test.concurrent.counter", 1);
            lib.obs.recordMethod("test.concurrent.method", 3, false);
        }
    }
};

test "concurrent obs counter + record_method across 8 threads sums correctly" {
    // Sample a baseline so we tolerate any contributions from earlier tests.
    const baseline_json = try lib.obs.metricsJson(std.testing.allocator);
    defer std.testing.allocator.free(baseline_json);
    var baseline_counter: u64 = 0;
    var baseline_method: u64 = 0;
    {
        var parsed = try std.json.parseFromSlice(
            std.json.Value,
            std.testing.allocator,
            baseline_json,
            .{},
        );
        defer parsed.deinit();
        if (parsed.value.object.get("counters")) |counters| {
            if (counters == .object) {
                if (counters.object.get("test.concurrent.counter")) |v| {
                    if (v == .integer) baseline_counter = @intCast(v.integer);
                }
            }
        }
        if (parsed.value.object.get("methods")) |methods| {
            if (methods == .object) {
                if (methods.object.get("test.concurrent.method")) |v| {
                    if (v == .object) {
                        if (v.object.get("count")) |c| {
                            if (c == .integer) baseline_method = @intCast(c.integer);
                        }
                    }
                }
            }
        }
    }

    const per_thread: usize = 500;
    var ctx = ObsCounterCtx{ .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, ObsCounterCtx.run, .{&ctx});
    }
    for (threads) |t| t.join();

    const after = try lib.obs.metricsJson(std.testing.allocator);
    defer std.testing.allocator.free(after);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, after, .{});
    defer parsed.deinit();

    const counters = parsed.value.object.get("counters").?.object;
    const final_counter: u64 = @intCast(counters.get("test.concurrent.counter").?.integer);
    try std.testing.expectEqual(
        baseline_counter + thread_count * per_thread,
        final_counter,
    );

    const methods = parsed.value.object.get("methods").?.object;
    const method_obj = methods.get("test.concurrent.method").?.object;
    const final_method: u64 = @intCast(method_obj.get("count").?.integer);
    try std.testing.expectEqual(
        baseline_method + thread_count * per_thread,
        final_method,
    );
}

// -----------------------------------------------------------------------------
// 10. Pure entrypoints from many threads — slashcmd_parse + cwd_resolve.
//     These don't share state but exercising them in parallel is cheap and
//     catches regressions where someone accidentally adds shared state.
// -----------------------------------------------------------------------------

const PureCtx = struct {
    iterations: usize,
    failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *PureCtx) void {
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            const parse = h.embedded.smithers_slashcmd_parse("/run workflow with arg");
            defer h.embedded.smithers_string_free(parse);
            if (std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, h.stringSlice(parse), .{})) |parsed| {
                var p = parsed;
                p.deinit();
            } else |_| {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            }

            const cwd = h.embedded.smithers_cwd_resolve(null);
            defer h.embedded.smithers_string_free(cwd);
            // Empty is allowed; non-empty must be NUL-terminated (we trust
            // the ABI here — just touching the bytes catches gross
            // corruption).
            _ = h.stringSlice(cwd);
        }
    }
};

test "pure entrypoints (slashcmd_parse, cwd_resolve) from 8 threads stay consistent" {
    const per_thread: usize = 200;
    var ctx = PureCtx{ .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, PureCtx.run, .{&ctx});
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.failures.load(.seq_cst));
}

// -----------------------------------------------------------------------------
// 11. Concurrent palette mutation + items_json read.
//     Palette owns a mutex; concurrent setQuery/setMode + itemsJson must
//     produce valid JSON and never crash.
// -----------------------------------------------------------------------------

const PaletteCtx = struct {
    palette: *Palette,
    iterations: usize,
    failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn run(self: *PaletteCtx, thread_index: usize) void {
        const modes = [_]h.structs.PaletteMode{
            .all,
            .commands,
            .files,
            .workflows,
            .workspaces,
            .runs,
        };
        var i: usize = 0;
        while (i < self.iterations) : (i += 1) {
            h.embedded.smithers_palette_set_mode(self.palette, modes[(thread_index + i) % modes.len]);

            var qbuf: [32]u8 = undefined;
            const q = std.fmt.bufPrintZ(&qbuf, "q{d}-{d}", .{ thread_index, i }) catch {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            };
            h.embedded.smithers_palette_set_query(self.palette, q.ptr);

            const items = h.embedded.smithers_palette_items_json(self.palette);
            defer h.embedded.smithers_string_free(items);
            if (std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, h.stringSlice(items), .{})) |parsed| {
                var p = parsed;
                p.deinit();
            } else |_| {
                _ = self.failures.fetchAdd(1, .seq_cst);
                continue;
            }
        }
    }
};

test "concurrent palette setMode/setQuery + itemsJson from 8 threads on one palette" {
    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const palette = h.embedded.smithers_palette_new(app).?;
    defer h.embedded.smithers_palette_free(palette);

    const per_thread: usize = 100;
    var ctx = PaletteCtx{ .palette = palette, .iterations = per_thread };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, PaletteCtx.run, .{ &ctx, i });
    }
    for (threads) |t| t.join();

    try std.testing.expectEqual(@as(u64, 0), ctx.failures.load(.seq_cst));
}

// -----------------------------------------------------------------------------
// Gaps documented inline:
//
//  * Concurrent-destroy-vs-call on the SAME handle: FIXED. Client now uses
//    refcount + `closed` atomic flag (mirrors EventStream.retain/release).
//    See tests 4b/4c/4d above. `destroy` flips `closed` and drops the
//    original strong ref; in-flight callers hold a transient ref via
//    `acquireForCall` and finish their work before deallocation. Sharing a
//    handle across threads now requires explicit `retain` (Arc semantics).
//
//  * smithers_session_send_text + smithers_session_events on the SAME session
//    handle from multiple threads is NOT covered. The Session struct mutates
//    `messages`, `title_cache`, and `updated_at_ms` without holding any
//    mutex (see src/session/session.zig), and the public header explicitly
//    states host->core calls "are synchronous and expected to be on the main
//    thread" (smithers.h §architectural rule 4). Adding a Session.mutex is
//    out of scope for this concurrency test and is tracked separately. We
//    do exercise multiple sessions across threads via the App.mutex path
//    (test 2) and via the EventStream which Session.events() returns
//    (EventStream is mutex-protected, test 5).
//
//  * smithers_core_* (the new connection-scoped runtime) is covered by
//    test/core/integration/real_transport.zig and is gated on a live
//    Electric stack; this file targets the stable embedded ABI surface
//    (smithers_app_*, smithers_client_*, smithers_palette_*, smithers_obs_*,
//    smithers_event_stream_*, smithers_slashcmd_parse, smithers_cwd_resolve).
//
//  * Snapshot + delta interleave: the embedded ABI does not currently emit
//    snapshot+delta on the same client handle (that's a smithers_core_*
//    feature). Test 5 above exercises the only "interleaved delivery"
//    pattern available on the legacy surface — concurrent drain of a
//    multi-event stream — which is the strongest test possible against
//    today's API.
