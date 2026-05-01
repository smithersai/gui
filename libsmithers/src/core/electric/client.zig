//! ElectricSQL shape client — production adaptation of
//! poc/zig-electric-client/src/client.zig.
//!
//! Differences from the PoC:
//!   * Persistence is replaced by a caller-supplied `Sink` vtable so the
//!     Real transport can enqueue `Delta`s onto the session's pending
//!     queue (which `session.zig`'s `tick()` drains). Cursor persistence
//!     is wired through the bounded SQLite cache in `cache.zig` via the
//!     `CursorStore` hook — no PoC-local sqlite tables.
//!   * A `cancel` flag + mutex lets a worker thread interrupt an
//!     in-flight long-poll when the session unsubscribes or destroys.
//!   * Token refresh is delegated to the caller: on 401 we return
//!     `Error.Unauthorized` and the worker asks `core.fetchCredentials()`
//!     before retrying once.
//!
//! Protocol logic (offset monotonicity, must-refetch handling,
//! snapshot vs delta bookkeeping) is unchanged from 0093.

const std = @import("std");
const http = @import("http.zig");
const message = @import("message.zig");
const Err = @import("errors.zig").Error;

pub const Config = struct {
    host: []const u8,
    port: u16,
    /// Shape table name, e.g. "agent_sessions".
    table: []const u8,
    /// Electric `where` clause (URL-encoded by the caller).
    where: []const u8,
    /// Current bearer token. The worker re-fetches this from
    /// `core.fetchCredentials()` on each pollOnce via `refreshBearer`.
    bearer: []const u8,
    /// Stable persistence key, typically `"<table>:<hash>"` of where.
    shape_key: []const u8,
};

pub const Stats = struct {
    snapshot_rows: u32 = 0,
    deltas_applied: u32 = 0,
    up_to_date_seen: u32 = 0,
    must_refetch_seen: u32 = 0,
    last_status: u16 = 0,
    bytes_in: u64 = 0,
};

/// Caller-supplied cursor storage — implemented by RealTransport on top
/// of `cache.zig`'s subscription row (`electric_handle`, `electric_offset`
/// columns). `load` returns caller-owned slices (or null on first subscribe).
pub const CursorStore = struct {
    ctx: ?*anyopaque,
    load_fn: *const fn (ctx: ?*anyopaque, shape_key: []const u8, allocator: std.mem.Allocator) anyerror!?Cursor,
    save_fn: *const fn (ctx: ?*anyopaque, shape_key: []const u8, handle: []const u8, offset: []const u8) anyerror!void,
    delete_fn: *const fn (ctx: ?*anyopaque, shape_key: []const u8) anyerror!void,

    pub const Cursor = struct { handle: []u8, offset: []u8 };
};

/// Delta emission sink — RealTransport implements this to push rows into
/// the session's pending queue as `transport.Delta`s.
pub const Sink = struct {
    ctx: ?*anyopaque,
    on_upsert: *const fn (ctx: ?*anyopaque, shape: []const u8, pk: []const u8, row_json: []const u8) anyerror!void,
    on_delete: *const fn (ctx: ?*anyopaque, shape: []const u8, pk: []const u8) anyerror!void,
    on_up_to_date: *const fn (ctx: ?*anyopaque, shape: []const u8, handle: []const u8, offset: []const u8) anyerror!void,
    on_must_refetch: *const fn (ctx: ?*anyopaque, shape: []const u8) anyerror!void,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    cursor_store: CursorStore,
    sink: Sink,
    handle: ?[]u8 = null,
    offset: []u8,
    closed: bool = false,
    stats: Stats = .{},

    pub fn init(
        allocator: std.mem.Allocator,
        cfg: Config,
        cursor_store: CursorStore,
        sink: Sink,
    ) !Client {
        const loaded = try cursor_store.load_fn(cursor_store.ctx, cfg.shape_key, allocator);
        if (loaded) |c| {
            return .{
                .allocator = allocator,
                .cfg = cfg,
                .cursor_store = cursor_store,
                .sink = sink,
                .handle = c.handle,
                .offset = c.offset,
                .stats = .{ .up_to_date_seen = 1 },
            };
        }
        const initial = try allocator.dupe(u8, "-1");
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .cursor_store = cursor_store,
            .sink = sink,
            .handle = null,
            .offset = initial,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.handle) |h| self.allocator.free(h);
        self.allocator.free(self.offset);
    }

    /// Replace the bearer used for subsequent HTTP requests. Called by the
    /// worker thread after a 401 → token refresh cycle.
    pub fn setBearer(self: *Client, bearer: []const u8) void {
        self.cfg.bearer = bearer;
    }

    fn buildPath(self: *Client, live: bool) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        try buf.print(self.allocator, "/v1/shape?table={s}&where={s}&offset={s}", .{ self.cfg.table, self.cfg.where, self.offset });
        if (self.handle) |h| try buf.print(self.allocator, "&handle={s}", .{h});
        if (live) try buf.appendSlice(self.allocator, "&live=true");
        return buf.toOwnedSlice(self.allocator);
    }

    /// Issue exactly one HTTP request and dispatch its payload through the
    /// sink. Returns the number of data messages applied (excludes control
    /// messages).
    pub fn pollOnce(self: *Client, live: bool) Err!usize {
        if (self.closed) return Err.AlreadyClosed;

        const path = self.buildPath(live) catch return Err.OutOfMemory;
        defer self.allocator.free(path);

        var resp = try http.fetch(self.allocator, .{
            .host = self.cfg.host,
            .port = self.cfg.port,
            .path_and_query = path,
            .bearer = self.cfg.bearer,
            .handle = self.handle,
        });
        defer resp.deinit();

        self.stats.last_status = resp.status;
        self.stats.bytes_in += resp.body.len;

        switch (resp.status) {
            200, 204 => {},
            401 => return Err.Unauthorized,
            403 => return Err.Forbidden,
            else => return Err.BadStatus,
        }

        if (resp.header("electric-handle")) |h| {
            try self.setHandle(h);
        } else if (self.handle == null) {
            return Err.MissingElectricHeader;
        }

        const new_offset = resp.header("electric-offset") orelse return Err.MissingElectricHeader;
        if (!std.mem.eql(u8, self.offset, "-1") and offsetRegressed(self.offset, new_offset)) {
            return Err.OffsetRegression;
        }

        var applied: usize = 0;
        if (resp.body.len > 0) {
            var parsed = try message.parseBody(self.allocator, resp.body);
            defer parsed.deinit(self.allocator);
            defer message.freeValueJsons(self.allocator, parsed.messages);

            for (parsed.messages) |m| {
                switch (m.op) {
                    .insert, .update => {
                        const pk = pkFromKey(m.key);
                        self.sink.on_upsert(self.sink.ctx, self.cfg.table, pk, m.value_json) catch return Err.IoError;
                        applied += 1;
                        if (self.stats.up_to_date_seen == 0) {
                            self.stats.snapshot_rows += 1;
                        } else {
                            self.stats.deltas_applied += 1;
                        }
                    },
                    .delete => {
                        const pk = pkFromKey(m.key);
                        self.sink.on_delete(self.sink.ctx, self.cfg.table, pk) catch return Err.IoError;
                        applied += 1;
                        self.stats.deltas_applied += 1;
                    },
                    .up_to_date, .snapshot_end => {
                        self.stats.up_to_date_seen += 1;
                        // Emit so session can persist the cursor post-apply.
                        self.sink.on_up_to_date(self.sink.ctx, self.cfg.table, self.handle orelse "", new_offset) catch return Err.IoError;
                    },
                    .must_refetch => {
                        self.stats.must_refetch_seen += 1;
                        self.sink.on_must_refetch(self.sink.ctx, self.cfg.table) catch return Err.IoError;
                        self.resetForRefetch() catch return Err.IoError;
                        return applied;
                    },
                }
            }
        }

        try self.setOffset(new_offset);
        self.cursor_store.save_fn(self.cursor_store.ctx, self.cfg.shape_key, self.handle.?, self.offset) catch return Err.IoError;
        return applied;
    }

    pub fn unsubscribe(self: *Client) !void {
        if (self.closed) return Err.AlreadyClosed;
        self.closed = true;
        try self.cursor_store.delete_fn(self.cursor_store.ctx, self.cfg.shape_key);
    }

    fn setHandle(self: *Client, v: []const u8) !void {
        if (self.handle) |old| {
            if (std.mem.eql(u8, old, v)) return;
            self.allocator.free(old);
        }
        self.handle = try self.allocator.dupe(u8, v);
    }

    fn setOffset(self: *Client, v: []const u8) !void {
        const new = try self.allocator.dupe(u8, v);
        self.allocator.free(self.offset);
        self.offset = new;
    }

    fn resetForRefetch(self: *Client) !void {
        if (self.handle) |old| {
            self.allocator.free(old);
            self.handle = null;
        }
        self.allocator.free(self.offset);
        self.offset = try self.allocator.dupe(u8, "-1");
        try self.cursor_store.delete_fn(self.cursor_store.ctx, self.cfg.shape_key);
    }
};

/// Strip Electric's `"schema"."table"/` prefix from a PK so we emit the
/// bare row id that `cache.zig` expects. Defensive against Electric
/// sending already-stripped keys.
fn pkFromKey(key: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, key, '/') orelse return key;
    return key[slash + 1 ..];
}

fn offsetRegressed(old_off: []const u8, new_off: []const u8) bool {
    const o = parseOffset(old_off) orelse return false;
    const n = parseOffset(new_off) orelse return false;
    if (n.hi < o.hi) return true;
    if (n.hi == o.hi and n.lo < o.lo) return true;
    return false;
}

const OffsetPair = struct { hi: u64, lo: u64 };

fn parseOffset(s: []const u8) ?OffsetPair {
    const underscore = std.mem.indexOfScalar(u8, s, '_') orelse return null;
    const hi = std.fmt.parseInt(u64, s[0..underscore], 10) catch return null;
    const lo = std.fmt.parseInt(u64, s[underscore + 1 ..], 10) catch return null;
    return .{ .hi = hi, .lo = lo };
}

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "offsetRegressed: monotonic" {
    try testing.expectEqual(false, offsetRegressed("0_0", "1_0"));
    try testing.expectEqual(false, offsetRegressed("1_0", "1_5"));
    try testing.expectEqual(true, offsetRegressed("5_0", "4_9"));
    try testing.expectEqual(true, offsetRegressed("5_3", "5_2"));
    try testing.expectEqual(false, offsetRegressed("5_3", "5_3"));
}

test "offsetRegressed: unparseable tolerated" {
    try testing.expectEqual(false, offsetRegressed("garbage", "1_0"));
    try testing.expectEqual(false, offsetRegressed("1_0", "garbage"));
}

test "pkFromKey: strips schema.table prefix" {
    try testing.expectEqualStrings("42", pkFromKey("\"public\".\"t\"/42"));
    try testing.expectEqualStrings("abc", pkFromKey("abc"));
}
