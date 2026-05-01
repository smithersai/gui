//! Bounded per-connection cache backed by SQLite.
//!
//! Spec: "Repurpose libsmithers/src/persistence/sqlite.zig from local
//! workspace/session persistence to the bounded per-connection cache."
//!
//! Scope for this landing:
//!   - Open an in-memory or path-backed sqlite with the 0120 schema
//!     (`schema.ddl`), which already mirrors all production shapes.
//!   - Live upsert/delete adapter for the `agent_sessions` table.
//!   - `query` returns a JSON array of `row_json` values for a shape.
//!   - Subscription registry + pinned flag.
//!   - `wipe` clears all rows (sign-out support, per 0133).
//!
//! Out of scope (TODO 0120-followup):
//!   - LRU / size-bounded eviction for `cache_max_mb`.
//!   - Live adapters for shapes other than agent_sessions.
//!   - Typed column projections (we store `row_json` as opaque).

const std = @import("std");
const schema = @import("schema.zig");

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
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
extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, value: i64) c_int;
extern fn sqlite3_bind_int(stmt: ?*sqlite3_stmt, idx: c_int, value: c_int) c_int;
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
extern fn sqlite3_last_insert_rowid(db: ?*sqlite3) i64;
extern fn sqlite3_changes(db: ?*sqlite3) c_int;

pub const Error = error{ Sqlite, OutOfMemory, UnknownShape };

pub const Cache = struct {
    allocator: std.mem.Allocator,
    db: ?*sqlite3,
    mutex: std.Thread.Mutex = .{},

    pub fn openInMemory(allocator: std.mem.Allocator) Error!*Cache {
        return openPath(allocator, ":memory:");
    }

    pub fn openPath(allocator: std.mem.Allocator, path: []const u8) Error!*Cache {
        const path_z = allocator.dupeZ(u8, path) catch return Error.OutOfMemory;
        defer allocator.free(path_z);

        var db: ?*sqlite3 = null;
        if (sqlite3_open(path_z.ptr, &db) != SQLITE_OK) {
            _ = sqlite3_close(db);
            return Error.Sqlite;
        }
        errdefer _ = sqlite3_close(db);

        const self = allocator.create(Cache) catch return Error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .db = db };

        try self.exec(schema.ddl);
        return self;
    }

    pub fn close(self: *Cache) void {
        _ = sqlite3_close(self.db);
        self.allocator.destroy(self);
    }

    fn exec(self: *Cache, sql: []const u8) Error!void {
        const z = self.allocator.dupeZ(u8, sql) catch return Error.OutOfMemory;
        defer self.allocator.free(z);
        if (sqlite3_exec(self.db, z.ptr, null, null, null) != SQLITE_OK) return Error.Sqlite;
    }

    // --- Subscription registry ------------------------------------------

    pub fn registerSubscription(
        self: *Cache,
        shape_name: []const u8,
        params_json: []const u8,
    ) Error!i64 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const sql = "INSERT INTO core_subscriptions(shape_name, params_json, pinned, created_unix_ms) VALUES (?1, ?2, 0, ?3);";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return Error.Sqlite;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_text(stmt, 1, shape_name.ptr, @intCast(shape_name.len), SQLITE_STATIC);
        _ = sqlite3_bind_text(stmt, 2, params_json.ptr, @intCast(params_json.len), SQLITE_STATIC);
        _ = sqlite3_bind_int64(stmt, 3, std.time.milliTimestamp());
        if (sqlite3_step(stmt) != SQLITE_DONE) return Error.Sqlite;
        return sqlite3_last_insert_rowid(self.db);
    }

    pub fn unregisterSubscription(self: *Cache, sub_id: i64) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Try each adapter table. For the skeleton this is fine; a more
        // granular design would route by the stored shape_name.
        const tables = [_][]const u8{
            "agent_sessions",         "agent_messages",      "agent_parts",
            "workspaces",             "workspace_sessions",  "approvals",
            "workflow_runs",          "devtools_snapshots",
        };
        for (tables) |t| {
            const sql = try std.fmt.allocPrintSentinel(
                self.allocator,
                "DELETE FROM {s} WHERE subscription_id=?1;",
                .{t},
                0,
            );
            defer self.allocator.free(sql);
            var stmt: ?*sqlite3_stmt = null;
            if (sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return Error.Sqlite;
            _ = sqlite3_bind_int64(stmt, 1, sub_id);
            _ = sqlite3_step(stmt);
            _ = sqlite3_finalize(stmt);
        }

        const del_sql = "DELETE FROM core_subscriptions WHERE id=?1;";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, del_sql, -1, &stmt, null) != SQLITE_OK) return Error.Sqlite;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int64(stmt, 1, sub_id);
        if (sqlite3_step(stmt) != SQLITE_DONE) return Error.Sqlite;
    }

    pub fn setPinned(self: *Cache, sub_id: i64, pinned: bool) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql = "UPDATE core_subscriptions SET pinned=?1 WHERE id=?2;";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return Error.Sqlite;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_int(stmt, 1, if (pinned) 1 else 0);
        _ = sqlite3_bind_int64(stmt, 2, sub_id);
        if (sqlite3_step(stmt) != SQLITE_DONE) return Error.Sqlite;
    }

    pub fn updateCursor(
        self: *Cache,
        sub_id: i64,
        handle: []const u8,
        offset: []const u8,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql = "UPDATE core_subscriptions SET electric_handle=?1, electric_offset=?2 WHERE id=?3;";
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != SQLITE_OK) return Error.Sqlite;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_text(stmt, 1, handle.ptr, @intCast(handle.len), SQLITE_STATIC);
        _ = sqlite3_bind_text(stmt, 2, offset.ptr, @intCast(offset.len), SQLITE_STATIC);
        _ = sqlite3_bind_int64(stmt, 3, sub_id);
        if (sqlite3_step(stmt) != SQLITE_DONE) return Error.Sqlite;
    }

    // --- Row application (live adapter) ---------------------------------

    /// Upsert a row into the shape's backing table. Returns UnknownShape
    /// if the shape name isn't recognised, else swallows no-ops for
    /// shapes without a live adapter (so transport code doesn't need to
    /// branch). Today only agent_sessions is live.
    pub fn upsertRow(
        self: *Cache,
        shape: schema.Shape,
        sub_id: i64,
        pk: []const u8,
        row_json: []const u8,
    ) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql = try std.fmt.allocPrintSentinel(
            self.allocator,
            "INSERT INTO {s}(pk, subscription_id, row_json, applied_unix_ms) VALUES (?1, ?2, ?3, ?4) ON CONFLICT(pk) DO UPDATE SET row_json=excluded.row_json, applied_unix_ms=excluded.applied_unix_ms;",
            .{shape.tableName()},
            0,
        );
        defer self.allocator.free(sql);
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return Error.Sqlite;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_text(stmt, 1, pk.ptr, @intCast(pk.len), SQLITE_STATIC);
        _ = sqlite3_bind_int64(stmt, 2, sub_id);
        _ = sqlite3_bind_text(stmt, 3, row_json.ptr, @intCast(row_json.len), SQLITE_STATIC);
        _ = sqlite3_bind_int64(stmt, 4, std.time.milliTimestamp());
        if (sqlite3_step(stmt) != SQLITE_DONE) return Error.Sqlite;
    }

    pub fn deleteRow(self: *Cache, shape: schema.Shape, pk: []const u8) Error!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const sql = try std.fmt.allocPrintSentinel(
            self.allocator,
            "DELETE FROM {s} WHERE pk=?1;",
            .{shape.tableName()},
            0,
        );
        defer self.allocator.free(sql);
        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return Error.Sqlite;
        defer _ = sqlite3_finalize(stmt);
        _ = sqlite3_bind_text(stmt, 1, pk.ptr, @intCast(pk.len), SQLITE_STATIC);
        if (sqlite3_step(stmt) != SQLITE_DONE) return Error.Sqlite;
    }

    /// Return a JSON array of `row_json` values for `shape`. `limit<=0`
    /// means unbounded. The caller owns the returned slice.
    pub fn queryJson(
        self: *Cache,
        shape: schema.Shape,
        limit: i32,
        offset: i32,
    ) Error![]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        var sql_buf: std.ArrayList(u8) = .empty;
        defer sql_buf.deinit(self.allocator);
        sql_buf.print(self.allocator, "SELECT row_json FROM {s} ORDER BY applied_unix_ms ASC", .{shape.tableName()}) catch return Error.OutOfMemory;
        if (limit > 0) sql_buf.print(self.allocator, " LIMIT {d}", .{limit}) catch return Error.OutOfMemory;
        if (offset > 0) sql_buf.print(self.allocator, " OFFSET {d}", .{offset}) catch return Error.OutOfMemory;
        sql_buf.append(self.allocator, ';') catch return Error.OutOfMemory;

        const sql_z = self.allocator.dupeZ(u8, sql_buf.items) catch return Error.OutOfMemory;
        defer self.allocator.free(sql_z);

        var stmt: ?*sqlite3_stmt = null;
        if (sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != SQLITE_OK) return Error.Sqlite;
        defer _ = sqlite3_finalize(stmt);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        out.append(self.allocator, '[') catch return Error.OutOfMemory;
        var first = true;
        while (true) {
            const rc = sqlite3_step(stmt);
            if (rc == SQLITE_DONE) break;
            if (rc != SQLITE_ROW) return Error.Sqlite;
            if (!first) out.append(self.allocator, ',') catch return Error.OutOfMemory;
            first = false;
            const v = sqlite3_column_text(stmt, 0) orelse continue;
            const n: usize = @intCast(sqlite3_column_bytes(stmt, 0));
            out.appendSlice(self.allocator, v[0..n]) catch return Error.OutOfMemory;
        }
        out.append(self.allocator, ']') catch return Error.OutOfMemory;
        return out.toOwnedSlice(self.allocator) catch return Error.OutOfMemory;
    }

    /// Hard-wipe all cached rows + subscriptions. Sign-out handler.
    pub fn wipe(self: *Cache) Error!void {
        try self.exec(
            \\DELETE FROM agent_sessions;
            \\DELETE FROM agent_messages;
            \\DELETE FROM agent_parts;
            \\DELETE FROM workspaces;
            \\DELETE FROM workspace_sessions;
            \\DELETE FROM approvals;
            \\DELETE FROM workflow_runs;
            \\DELETE FROM devtools_snapshots;
            \\DELETE FROM core_subscriptions;
        );
    }
};

// -----------------------------------------------------------------------
// Tests
// -----------------------------------------------------------------------

const testing = std.testing;

test "Cache: open in memory and wipe empty db" {
    const c = try Cache.openInMemory(testing.allocator);
    defer c.close();
    try c.wipe();
}

test "Cache: subscription register/unregister" {
    const c = try Cache.openInMemory(testing.allocator);
    defer c.close();
    const id = try c.registerSubscription("agent_sessions", "{\"repo\":1}");
    try testing.expect(id > 0);
    try c.setPinned(id, true);
    try c.setPinned(id, false);
    try c.updateCursor(id, "handle-1", "0_7");
    try c.unregisterSubscription(id);
}

test "Cache: agent_sessions upsert and queryJson" {
    const c = try Cache.openInMemory(testing.allocator);
    defer c.close();
    const id = try c.registerSubscription("agent_sessions", "{}");
    try c.upsertRow(.agent_sessions, id, "as_1", "{\"id\":\"as_1\",\"title\":\"a\"}");
    try c.upsertRow(.agent_sessions, id, "as_2", "{\"id\":\"as_2\",\"title\":\"b\"}");

    const rows = try c.queryJson(.agent_sessions, 0, 0);
    defer testing.allocator.free(rows);
    try testing.expect(std.mem.indexOf(u8, rows, "as_1") != null);
    try testing.expect(std.mem.indexOf(u8, rows, "as_2") != null);
    // well-formed JSON array bookends
    try testing.expectEqual(@as(u8, '['), rows[0]);
    try testing.expectEqual(@as(u8, ']'), rows[rows.len - 1]);
}

test "Cache: upsert same pk updates row" {
    const c = try Cache.openInMemory(testing.allocator);
    defer c.close();
    const id = try c.registerSubscription("agent_sessions", "{}");
    try c.upsertRow(.agent_sessions, id, "as_1", "{\"v\":1}");
    try c.upsertRow(.agent_sessions, id, "as_1", "{\"v\":2}");
    const rows = try c.queryJson(.agent_sessions, 0, 0);
    defer testing.allocator.free(rows);
    try testing.expect(std.mem.indexOf(u8, rows, "\"v\":2") != null);
    try testing.expect(std.mem.indexOf(u8, rows, "\"v\":1") == null);
}

test "Cache: deleteRow drops pk" {
    const c = try Cache.openInMemory(testing.allocator);
    defer c.close();
    const id = try c.registerSubscription("agent_sessions", "{}");
    try c.upsertRow(.agent_sessions, id, "as_1", "{\"v\":1}");
    try c.deleteRow(.agent_sessions, "as_1");
    const rows = try c.queryJson(.agent_sessions, 0, 0);
    defer testing.allocator.free(rows);
    try testing.expectEqualStrings("[]", rows);
}

test "Cache: wipe clears all rows" {
    const c = try Cache.openInMemory(testing.allocator);
    defer c.close();
    const id = try c.registerSubscription("agent_sessions", "{}");
    try c.upsertRow(.agent_sessions, id, "as_1", "{\"v\":1}");
    try c.wipe();
    const rows = try c.queryJson(.agent_sessions, 0, 0);
    defer testing.allocator.free(rows);
    try testing.expectEqualStrings("[]", rows);
}
