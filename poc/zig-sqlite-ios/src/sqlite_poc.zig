//! Minimal SQLite wrapper for the iOS PoC.
//!
//! Adapted from `libsmithers/src/persistence/sqlite.zig`. Links against the
//! iOS system `libsqlite3` via `-lsqlite3`. No vendored SQLite, no SQLCipher,
//! no WAL test harness — that all lives in the production wrapper.

const std = @import("std");

const SQLITE_OK: c_int = 0;
const SQLITE_ROW: c_int = 100;
const SQLITE_DONE: c_int = 101;

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
extern fn sqlite3_free(ptr: ?*anyopaque) void;
extern fn sqlite3_prepare_v2(
    db: ?*sqlite3,
    sql: [*:0]const u8,
    nByte: c_int,
    ppStmt: *?*sqlite3_stmt,
    pzTail: ?*?[*:0]const u8,
) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(
    stmt: ?*sqlite3_stmt,
    idx: c_int,
    value: [*]const u8,
    n: c_int,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) c_int;
extern fn sqlite3_bind_int64(stmt: ?*sqlite3_stmt, idx: c_int, value: i64) c_int;
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;
extern fn sqlite3_column_int64(stmt: ?*sqlite3_stmt, iCol: c_int) i64;
extern fn sqlite3_busy_timeout(db: ?*sqlite3, ms: c_int) c_int;

const allocator: std.mem.Allocator = std.heap.c_allocator;

const Handle = struct {
    db: ?*sqlite3,
    last_error: [:0]u8,
};

threadlocal var last_open_error: [256]u8 = [_]u8{0} ** 256;

fn setOpenError(msg: []const u8) void {
    const n = @min(msg.len, last_open_error.len - 1);
    @memcpy(last_open_error[0..n], msg[0..n]);
    last_open_error[n] = 0;
}

fn setLastError(h: *Handle, msg: []const u8) void {
    allocator.free(h.last_error);
    h.last_error = allocator.dupeZ(u8, msg) catch blk: {
        const fallback = allocator.dupeZ(u8, "out of memory") catch @panic("oom");
        break :blk fallback;
    };
}

export fn sqpoc_open(path: ?[*:0]const u8) callconv(.c) ?*Handle {
    const p = path orelse {
        setOpenError("null path");
        return null;
    };
    const path_slice = std.mem.sliceTo(p, 0);

    var db: ?*sqlite3 = null;
    if (sqlite3_open(path_slice.ptr, &db) != SQLITE_OK) {
        if (db) |d| {
            const msg = std.mem.sliceTo(sqlite3_errmsg(d), 0);
            setOpenError(msg);
            _ = sqlite3_close(d);
        } else {
            setOpenError("sqlite3_open returned error with null db");
        }
        return null;
    }

    _ = sqlite3_busy_timeout(db, 5000);

    const schema =
        "CREATE TABLE IF NOT EXISTS poc (id INTEGER PRIMARY KEY, text TEXT NOT NULL);";
    var errmsg: ?[*:0]u8 = null;
    if (sqlite3_exec(db, schema, null, null, &errmsg) != SQLITE_OK) {
        if (errmsg) |m| {
            setOpenError(std.mem.sliceTo(m, 0));
            sqlite3_free(m);
        } else {
            setOpenError("schema creation failed");
        }
        _ = sqlite3_close(db);
        return null;
    }

    const h = allocator.create(Handle) catch {
        _ = sqlite3_close(db);
        setOpenError("out of memory");
        return null;
    };
    const empty = allocator.dupeZ(u8, "") catch {
        allocator.destroy(h);
        _ = sqlite3_close(db);
        setOpenError("out of memory");
        return null;
    };
    h.* = .{ .db = db, .last_error = empty };
    return h;
}

export fn sqpoc_open_error() callconv(.c) [*:0]const u8 {
    return @ptrCast(&last_open_error);
}

export fn sqpoc_close(h: ?*Handle) callconv(.c) void {
    const hh = h orelse return;
    if (hh.db) |d| _ = sqlite3_close(d);
    allocator.free(hh.last_error);
    allocator.destroy(hh);
}

export fn sqpoc_insert_row(h: ?*Handle, id: i64, text: ?[*:0]const u8) callconv(.c) i32 {
    const hh = h orelse return 1;
    const t = text orelse {
        setLastError(hh, "null text");
        return 1;
    };
    const slice = std.mem.sliceTo(t, 0);

    const sql = "INSERT OR REPLACE INTO poc (id, text) VALUES (?, ?);";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(hh.db, sql, -1, &stmt, null) != SQLITE_OK) {
        setLastError(hh, std.mem.sliceTo(sqlite3_errmsg(hh.db), 0));
        return 1;
    }
    defer _ = sqlite3_finalize(stmt);

    if (sqlite3_bind_int64(stmt, 1, id) != SQLITE_OK) {
        setLastError(hh, std.mem.sliceTo(sqlite3_errmsg(hh.db), 0));
        return 1;
    }
    const len_i32: c_int = @intCast(slice.len);
    if (sqlite3_bind_text(stmt, 2, slice.ptr, len_i32, null) != SQLITE_OK) {
        setLastError(hh, std.mem.sliceTo(sqlite3_errmsg(hh.db), 0));
        return 1;
    }

    if (sqlite3_step(stmt) != SQLITE_DONE) {
        setLastError(hh, std.mem.sliceTo(sqlite3_errmsg(hh.db), 0));
        return 1;
    }
    return 0;
}

export fn sqpoc_count_rows(h: ?*Handle) callconv(.c) i64 {
    const hh = h orelse return -1;
    const sql = "SELECT COUNT(*) FROM poc;";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(hh.db, sql, -1, &stmt, null) != SQLITE_OK) {
        setLastError(hh, std.mem.sliceTo(sqlite3_errmsg(hh.db), 0));
        return -1;
    }
    defer _ = sqlite3_finalize(stmt);
    if (sqlite3_step(stmt) != SQLITE_ROW) {
        setLastError(hh, std.mem.sliceTo(sqlite3_errmsg(hh.db), 0));
        return -1;
    }
    return sqlite3_column_int64(stmt, 0);
}

export fn sqpoc_get_text(
    h: ?*Handle,
    id: i64,
    buf: ?[*]u8,
    buf_len: i32,
) callconv(.c) i64 {
    const hh = h orelse return -2;
    const out = buf orelse return -2;
    if (buf_len <= 0) return -2;

    const sql = "SELECT text FROM poc WHERE id = ? LIMIT 1;";
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(hh.db, sql, -1, &stmt, null) != SQLITE_OK) {
        setLastError(hh, std.mem.sliceTo(sqlite3_errmsg(hh.db), 0));
        return -2;
    }
    defer _ = sqlite3_finalize(stmt);
    if (sqlite3_bind_int64(stmt, 1, id) != SQLITE_OK) {
        setLastError(hh, std.mem.sliceTo(sqlite3_errmsg(hh.db), 0));
        return -2;
    }
    const rc = sqlite3_step(stmt);
    if (rc == SQLITE_DONE) return -1;
    if (rc != SQLITE_ROW) {
        setLastError(hh, std.mem.sliceTo(sqlite3_errmsg(hh.db), 0));
        return -2;
    }
    const text = sqlite3_column_text(stmt, 0) orelse return -1;
    const len: usize = @intCast(sqlite3_column_bytes(stmt, 0));
    const cap: usize = @intCast(buf_len - 1);
    const copy = @min(len, cap);
    @memcpy(out[0..copy], text[0..copy]);
    out[copy] = 0;
    return @intCast(len);
}

export fn sqpoc_last_error(h: ?*Handle) callconv(.c) [*:0]const u8 {
    const hh = h orelse return "";
    return hh.last_error.ptr;
}

// ---- host-side tests -------------------------------------------------------
// These run on macOS (zig build test). The iOS sandbox path is tested from
// XCTest in the Xcode harness.

const testing = std.testing;

test "open/insert/query/close round-trip on host" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path_rel = "poc.sqlite";
    try tmp.dir.writeFile(.{ .sub_path = db_path_rel, .data = "" });
    const db_path = try tmp.dir.realpathAlloc(testing.allocator, db_path_rel);
    defer testing.allocator.free(db_path);
    const db_path_z = try testing.allocator.dupeZ(u8, db_path);
    defer testing.allocator.free(db_path_z);

    const h = sqpoc_open(db_path_z.ptr);
    try testing.expect(h != null);
    defer sqpoc_close(h);

    const N: i64 = 50;
    var i: i64 = 0;
    while (i < N) : (i += 1) {
        var buf: [32]u8 = undefined;
        const text = try std.fmt.bufPrintZ(&buf, "row-{d}", .{i});
        try testing.expectEqual(@as(i32, 0), sqpoc_insert_row(h, i, text.ptr));
    }

    try testing.expectEqual(N, sqpoc_count_rows(h));

    var out: [64]u8 = undefined;
    const len = sqpoc_get_text(h, 7, &out, @intCast(out.len));
    try testing.expect(len >= 0);
    try testing.expectEqualStrings("row-7", std.mem.sliceTo(@as([*:0]u8, @ptrCast(&out)), 0));
}
