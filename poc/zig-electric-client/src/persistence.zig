//! Persistence for the Electric shape client.
//!
//! Two pieces of state have to survive client restarts:
//!   1. The shape **handle** Electric assigns on the first response (a
//!      server-side shape id). Sent back on every follow-up long-poll via
//!      the `electric-handle` HTTP header.
//!   2. The last acknowledged **offset** — the protocol's monotonic
//!      LSN-like token. Sent back as `?offset=<value>` on each request.
//!
//! For the PoC we keep this in a tiny SQLite table. In libsmithers-core
//! the real implementation will also mirror rows into per-shape tables;
//! here we only need the sync-cursor table plus a synthetic `poc_items`
//! table that the tests use to assert ordering.
//!
//! We deliberately do NOT reuse `libsmithers/src/persistence/sqlite.zig`
//! in-tree — that wrapper is tied to libsmithers' schema. Instead we
//! declare the exact same `extern fn` set here (see header comment in
//! that file). Adapting rather than forking keeps the FFI surface tiny
//! and avoids circular dependencies.

const std = @import("std");
const Err = @import("errors.zig").Error;

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
// We pass SQLITE_STATIC (null destructor) to sqlite3_bind_text. That's
// safe here because every call site holds the backing slice alive until
// after `sqlite3_step` returns — the slices either live on the stack or
// are owned by the Persistence caller.
const SQLITE_STATIC: ?*const fn (?*anyopaque) callconv(.c) void = null;

const sqlite3 = opaque {};
const sqlite3_stmt = opaque {};

extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*sqlite3) c_int;
extern fn sqlite3_close(db: ?*sqlite3) c_int;
extern fn sqlite3_errmsg(db: ?*sqlite3) [*:0]const u8;
extern fn sqlite3_exec(
    db: ?*sqlite3,
    sql: [*:0]const u8,
    callback: ?*const fn (?*anyopaque, c_int, ?[*]?[*:0]u8, ?[*]?[*:0]u8) callconv(.c) c_int,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;
extern fn sqlite3_prepare_v2(db: ?*sqlite3, sql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*:0]const u8) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, value: [*]const u8, n: c_int, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;

pub const Persistence = struct {
    allocator: std.mem.Allocator,
    db: ?*sqlite3,

    pub fn openInMemory(allocator: std.mem.Allocator) !*Persistence {
        return openPath(allocator, ":memory:");
    }

    pub fn openPath(allocator: std.mem.Allocator, path: []const u8) !*Persistence {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var db: ?*sqlite3 = null;
        if (sqlite3_open(path_z.ptr, &db) != SQLITE_OK) {
            _ = sqlite3_close(db);
            return Err.IoError;
        }
        errdefer _ = sqlite3_close(db);

        const p = try allocator.create(Persistence);
        errdefer allocator.destroy(p);
        p.* = .{ .allocator = allocator, .db = db };

        try p.exec(
            \\CREATE TABLE IF NOT EXISTS electric_shape_cursor (
            \\  shape_key TEXT PRIMARY KEY,
            \\  handle    TEXT NOT NULL,
            \\  offset_token TEXT NOT NULL
            \\);
            \\CREATE TABLE IF NOT EXISTS poc_items (
            \\  pk TEXT PRIMARY KEY,
            \\  value_json TEXT NOT NULL
            \\);
        );
        return p;
    }

    pub fn close(self: *Persistence) void {
        _ = sqlite3_close(self.db);
        self.allocator.destroy(self);
    }

    fn exec(self: *Persistence, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (sqlite3_exec(self.db, sql_z.ptr, null, null, null) != SQLITE_OK) return Err.IoError;
    }

    pub const Cursor = struct { handle: []u8, offset: []u8 };

    /// Return the persisted cursor for `shape_key`, or null if absent. The
    /// returned strings are caller-owned.
    pub fn loadCursor(self: *Persistence, shape_key: []const u8) !?Cursor {
        const sql = "SELECT handle, offset_token FROM electric_shape_cursor WHERE shape_key=?1;";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return Err.IoError;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_text(stmt, 1, shape_key.ptr, @intCast(shape_key.len), SQLITE_STATIC);
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) return null;
        if (rc != SQLITE_ROW) return Err.IoError;

        const h_c = sqlite3_column_text(stmt, 0) orelse return Err.IoError;
        const h_n: usize = @intCast(sqlite3_column_bytes(stmt, 0));
        const o_c = sqlite3_column_text(stmt, 1) orelse return Err.IoError;
        const o_n: usize = @intCast(sqlite3_column_bytes(stmt, 1));
        const h_copy = try self.allocator.dupe(u8, h_c[0..h_n]);
        errdefer self.allocator.free(h_copy);
        const o_copy = try self.allocator.dupe(u8, o_c[0..o_n]);
        return Cursor{ .handle = h_copy, .offset = o_copy };
    }

    pub fn saveCursor(self: *Persistence, shape_key: []const u8, handle: []const u8, offset: []const u8) !void {
        const sql = "INSERT INTO electric_shape_cursor(shape_key,handle,offset_token) VALUES(?1,?2,?3) ON CONFLICT(shape_key) DO UPDATE SET handle=excluded.handle, offset_token=excluded.offset_token;";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return Err.IoError;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_text(stmt, 1, shape_key.ptr, @intCast(shape_key.len), SQLITE_STATIC);
        _ = sqlite3_bind_text(stmt, 2, handle.ptr, @intCast(handle.len), SQLITE_STATIC);
        _ = sqlite3_bind_text(stmt, 3, offset.ptr, @intCast(offset.len), SQLITE_STATIC);
        if (sqlite3_step(stmt) != SQLITE_DONE) return Err.IoError;
    }

    pub fn deleteCursor(self: *Persistence, shape_key: []const u8) !void {
        const sql = "DELETE FROM electric_shape_cursor WHERE shape_key=?1;";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return Err.IoError;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_text(stmt, 1, shape_key.ptr, @intCast(shape_key.len), SQLITE_STATIC);
        if (sqlite3_step(stmt) != SQLITE_DONE) return Err.IoError;
    }

    pub fn upsertItem(self: *Persistence, pk: []const u8, value_json: []const u8) !void {
        const sql = "INSERT INTO poc_items(pk,value_json) VALUES(?1,?2) ON CONFLICT(pk) DO UPDATE SET value_json=excluded.value_json;";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return Err.IoError;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_text(stmt, 1, pk.ptr, @intCast(pk.len), SQLITE_STATIC);
        _ = sqlite3_bind_text(stmt, 2, value_json.ptr, @intCast(value_json.len), SQLITE_STATIC);
        if (sqlite3_step(stmt) != SQLITE_DONE) return Err.IoError;
    }

    pub fn deleteItem(self: *Persistence, pk: []const u8) !void {
        const sql = "DELETE FROM poc_items WHERE pk=?1;";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return Err.IoError;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_text(stmt, 1, pk.ptr, @intCast(pk.len), SQLITE_STATIC);
        if (sqlite3_step(stmt) != SQLITE_DONE) return Err.IoError;
    }

    pub fn countItems(self: *Persistence) !usize {
        const sql = "SELECT COUNT(*) FROM poc_items;";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return Err.IoError;
        defer _ = sqlite3_finalize(stmt);
        if (sqlite3_step(stmt) != SQLITE_ROW) return Err.IoError;
        const c = sqlite3_column_text(stmt, 0) orelse return 0;
        const n: usize = @intCast(sqlite3_column_bytes(stmt, 0));
        return std.fmt.parseInt(usize, c[0..n], 10) catch Err.IoError;
    }

    pub fn getItem(self: *Persistence, pk: []const u8) !?[]u8 {
        const sql = "SELECT value_json FROM poc_items WHERE pk=?1;";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return Err.IoError;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_text(stmt, 1, pk.ptr, @intCast(pk.len), SQLITE_STATIC);
        const rc = sqlite3_step(stmt);
        if (rc == SQLITE_DONE) return null;
        if (rc != SQLITE_ROW) return Err.IoError;
        const v = sqlite3_column_text(stmt, 0) orelse return null;
        const n: usize = @intCast(sqlite3_column_bytes(stmt, 0));
        return try self.allocator.dupe(u8, v[0..n]);
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "Persistence: round-trip cursor" {
    var p = try Persistence.openInMemory(testing.allocator);
    defer p.close();
    try testing.expect((try p.loadCursor("shape:A")) == null);
    try p.saveCursor("shape:A", "h-1", "off-0_0");
    const c1 = (try p.loadCursor("shape:A")).?;
    defer testing.allocator.free(c1.handle);
    defer testing.allocator.free(c1.offset);
    try testing.expectEqualStrings("h-1", c1.handle);
    try testing.expectEqualStrings("off-0_0", c1.offset);

    // Update (upsert).
    try p.saveCursor("shape:A", "h-1", "off-42_7");
    const c2 = (try p.loadCursor("shape:A")).?;
    defer testing.allocator.free(c2.handle);
    defer testing.allocator.free(c2.offset);
    try testing.expectEqualStrings("off-42_7", c2.offset);

    try p.deleteCursor("shape:A");
    try testing.expect((try p.loadCursor("shape:A")) == null);
}

test "Persistence: upsert and delete items" {
    var p = try Persistence.openInMemory(testing.allocator);
    defer p.close();
    try testing.expectEqual(@as(usize, 0), try p.countItems());
    try p.upsertItem("k1", "{\"n\":1}");
    try p.upsertItem("k2", "{\"n\":2}");
    try testing.expectEqual(@as(usize, 2), try p.countItems());
    const v = (try p.getItem("k1")).?;
    defer testing.allocator.free(v);
    try testing.expectEqualStrings("{\"n\":1}", v);
    try p.upsertItem("k1", "{\"n\":99}");
    const v2 = (try p.getItem("k1")).?;
    defer testing.allocator.free(v2);
    try testing.expectEqualStrings("{\"n\":99}", v2);
    try p.deleteItem("k1");
    try testing.expect((try p.getItem("k1")) == null);
    try testing.expectEqual(@as(usize, 1), try p.countItems());
}
