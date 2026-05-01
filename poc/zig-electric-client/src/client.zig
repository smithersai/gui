//! ElectricSQL shape client — orchestrates snapshot fetch + long-poll
//! loop against plue's auth proxy.
//!
//! Protocol flow (distilled from @electric-sql/client and plue's
//! oss/packages/sdk/src/services/sync.ts):
//!
//!   1. First request: GET /v1/shape?table=<t>&where=<w>&offset=-1
//!      - Server responds with the snapshot (possibly spanning multiple
//!        fetches if the server caps the batch size). Each response
//!        carries `electric-handle` and `electric-offset` headers.
//!      - When offset comes back == server's current offset the snapshot
//!        is complete — signalled by an `up-to-date` control message.
//!
//!   2. Subsequent requests: GET /v1/shape?table=<t>&where=<w>
//!                                        &offset=<last>&handle=<h>&live=true
//!      - Long-polls for up to ~20s; returns either new deltas or an
//!        `up-to-date` control so the client can resume.
//!
//!   3. `must-refetch` control: the server has truncated its log; the
//!      client must delete local state for the shape and start over with
//!      offset=-1.
//!
//! What this PoC does NOT do:
//!   - Concurrent shapes (one client, one shape)
//!   - Retry/backoff policy (left to the caller)
//!   - Streaming of partial JSON arrays
//!   - TLS (dev stack is HTTP; documented in README)

const std = @import("std");
const http = @import("http.zig");
const message = @import("message.zig");
const Persistence = @import("persistence.zig").Persistence;
const Err = @import("errors.zig").Error;

pub const Config = struct {
    host: []const u8,
    port: u16,
    table: []const u8,
    where: []const u8,
    /// Bearer token for plue's auth proxy (jjhub_xxx / jjhub_oat_xxx).
    bearer: []const u8,
    /// Stable identifier used as the persistence key for this shape's
    /// cursor row. Typical format: "<table>:<hash-of-where>".
    shape_key: []const u8,
    /// Max iterations of the long-poll loop per `pollOnce` invocation.
    /// Exposed so integration tests can bound how long they run.
    max_empty_polls: u32 = 1,
};

pub const Stats = struct {
    snapshot_rows: u32 = 0,
    deltas_applied: u32 = 0,
    up_to_date_seen: u32 = 0,
    must_refetch_seen: u32 = 0,
    last_status: u16 = 0,
    bytes_in: u64 = 0,
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    cfg: Config,
    persistence: *Persistence,
    handle: ?[]u8 = null,
    offset: []u8,
    closed: bool = false,
    stats: Stats = .{},

    /// Resume from persisted cursor if present, otherwise start at offset=-1.
    pub fn init(allocator: std.mem.Allocator, cfg: Config, persistence: *Persistence) !Client {
        const cursor = try persistence.loadCursor(cfg.shape_key);
        if (cursor) |c| {
            return .{
                .allocator = allocator,
                .cfg = cfg,
                .persistence = persistence,
                .handle = c.handle,
                .offset = c.offset,
                // Resuming from a persisted cursor means we already
                // caught up in a previous session — start in the
                // "post-snapshot" regime so incoming rows count as
                // deltas, not part of the initial snapshot.
                .stats = .{ .up_to_date_seen = 1 },
            };
        }
        const initial = try allocator.dupe(u8, "-1");
        return .{
            .allocator = allocator,
            .cfg = cfg,
            .persistence = persistence,
            .handle = null,
            .offset = initial,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.handle) |h| self.allocator.free(h);
        self.allocator.free(self.offset);
    }

    fn buildPath(self: *Client, live: bool) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(self.allocator);
        try buf.print(self.allocator, "/v1/shape?table={s}&where={s}&offset={s}", .{ self.cfg.table, self.cfg.where, self.offset });
        if (self.handle) |h| try buf.print(self.allocator, "&handle={s}", .{h});
        if (live) try buf.appendSlice(self.allocator, "&live=true");
        return buf.toOwnedSlice(self.allocator);
    }

    /// Issue exactly one HTTP request and apply its payload. Returns the
    /// number of *data* messages applied (excludes control messages).
    /// Use `pollOnce` in a loop until `stats.up_to_date_seen` advances.
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

        // Capture / update handle + offset from the response headers.
        if (resp.header("electric-handle")) |h| {
            try self.setHandle(h);
        } else if (self.handle == null) {
            // First response MUST carry a handle. If it doesn't, the
            // server is not the Electric we expect.
            return Err.MissingElectricHeader;
        }

        const new_offset = resp.header("electric-offset") orelse return Err.MissingElectricHeader;
        // Guard against server bugs that would hand us a regressed offset —
        // this would break the "no duplicates, no gaps" contract. `-1` is
        // only valid on the very first request.
        if (!std.mem.eql(u8, self.offset, "-1") and offsetRegressed(self.offset, new_offset)) {
            return Err.OffsetRegression;
        }

        var applied: usize = 0;
        if (resp.body.len > 0) {
            var parsed = try message.parseBody(self.allocator, resp.body);
            // Order matters: freeValueJsons walks parsed.messages, so it
            // must run before parsed.deinit (which frees the messages
            // slice itself). Defers are LIFO — declare deinit first so
            // free-values runs first.
            defer parsed.deinit(self.allocator);
            defer message.freeValueJsons(self.allocator, parsed.messages);

            for (parsed.messages) |m| {
                switch (m.op) {
                    .insert, .update => {
                        self.persistence.upsertItem(m.key, m.value_json) catch return Err.IoError;
                        applied += 1;
                        // "Snapshot" ends when we've seen our first
                        // up-to-date. Any inserts before that (across
                        // any number of chunked responses) are part of
                        // the initial load; anything after is a delta.
                        if (self.stats.up_to_date_seen == 0) {
                            self.stats.snapshot_rows += 1;
                        } else {
                            self.stats.deltas_applied += 1;
                        }
                    },
                    .delete => {
                        self.persistence.deleteItem(m.key) catch return Err.IoError;
                        applied += 1;
                        self.stats.deltas_applied += 1;
                    },
                    .up_to_date => {
                        self.stats.up_to_date_seen += 1;
                    },
                    .snapshot_end => {
                        // Older Electric emitted this; treat it like
                        // up-to-date for our PoC purposes.
                        self.stats.up_to_date_seen += 1;
                    },
                    .must_refetch => {
                        // Protocol says: wipe local state, reset cursor.
                        self.stats.must_refetch_seen += 1;
                        try self.resetForRefetch();
                        return applied;
                    },
                }
            }
        }

        // Commit new offset after successful application.
        try self.setOffset(new_offset);
        self.persistence.saveCursor(self.cfg.shape_key, self.handle.?, self.offset) catch return Err.IoError;
        return applied;
    }

    /// Drive the shape to "caught up" — fetch until an `up-to-date`
    /// control arrives. Returns once we've seen at least one up-to-date.
    pub fn catchUp(self: *Client) Err!void {
        const starting = self.stats.up_to_date_seen;
        // Snapshot + live-poll loop, bounded so unit tests can't hang.
        var iter: u32 = 0;
        while (self.stats.up_to_date_seen == starting) : (iter += 1) {
            if (iter >= 64) return Err.IoError;
            _ = try self.pollOnce(iter != 0);
        }
    }

    /// Drop the stored cursor (ideally also the rows, but that's the
    /// caller's concern since the PoC table is shared with the test).
    pub fn unsubscribe(self: *Client) !void {
        if (self.closed) return Err.AlreadyClosed;
        self.closed = true;
        try self.persistence.deleteCursor(self.cfg.shape_key);
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
        try self.persistence.deleteCursor(self.cfg.shape_key);
    }
};

/// Compare two Electric offset tokens. Electric offsets are `lsn_hi_lsn_lo`
/// decimal strings; higher pair means newer data. Returns true when
/// `new_off` is strictly older than `old_off`.
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
