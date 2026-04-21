const std = @import("std");
const ffi = @import("../ffi.zig");
const structs = @import("../apprt/structs.zig");

const SQLITE_OK = 0;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;

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
extern fn sqlite3_prepare_v2(db: ?*sqlite3, sql: [*:0]const u8, nByte: c_int, ppStmt: *?*sqlite3_stmt, pzTail: ?*?[*:0]const u8) c_int;
extern fn sqlite3_step(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_finalize(stmt: ?*sqlite3_stmt) c_int;
extern fn sqlite3_bind_text(stmt: ?*sqlite3_stmt, idx: c_int, value: [*]const u8, n: c_int, destructor: ?*const fn (?*anyopaque) callconv(.c) void) c_int;
extern fn sqlite3_column_text(stmt: ?*sqlite3_stmt, iCol: c_int) ?[*:0]const u8;
extern fn sqlite3_column_bytes(stmt: ?*sqlite3_stmt, iCol: c_int) c_int;

pub const Persistence = @This();

allocator: std.mem.Allocator,
mutex: std.Thread.Mutex = .{},
db: ?*sqlite3,

pub fn open(allocator: std.mem.Allocator, db_path: []const u8) !*Persistence {
    const path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(path_z);

    var db: ?*sqlite3 = null;
    if (sqlite3_open(path_z.ptr, &db) != SQLITE_OK) {
        defer _ = sqlite3_close(db);
        return error.OpenFailed;
    }
    errdefer _ = sqlite3_close(db);

    const p = try allocator.create(Persistence);
    errdefer allocator.destroy(p);
    p.* = .{ .allocator = allocator, .db = db };

    try p.ensureSchema();
    return p;
}

pub fn close(self: *Persistence) void {
    self.mutex.lock();
    const db = self.db;
    self.db = null;
    _ = sqlite3_close(db);
    self.mutex.unlock();
    self.allocator.destroy(self);
}

pub fn loadSessions(self: *Persistence, workspace_path: []const u8) structs.String {
    self.mutex.lock();
    defer self.mutex.unlock();
    const sql =
        \\SELECT sessions_json
        \\FROM workspace_sessions
        \\WHERE workspace_path = ?
        \\LIMIT 1;
    ;
    const stmt = self.prepare(sql) catch return ffi.stringDup("[]");
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, workspace_path) != SQLITE_OK) return ffi.stringDup("[]");
    const rc = sqlite3_step(stmt);
    if (rc != SQLITE_ROW) return ffi.stringDup("[]");
    const text = sqlite3_column_text(stmt, 0) orelse return ffi.stringDup("[]");
    const len: usize = @intCast(sqlite3_column_bytes(stmt, 0));
    return ffi.stringDup(text[0..len]);
}

pub fn saveSessions(self: *Persistence, workspace_path: []const u8, sessions_json: []const u8) structs.Error {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (!isValidJsonArray(sessions_json)) return ffi.errorMessage(2, "sessions_json must be a JSON array");
    const sql =
        \\INSERT INTO workspace_sessions (workspace_path, sessions_json, updated_at)
        \\VALUES (?, ?, strftime('%s', 'now'))
        \\ON CONFLICT(workspace_path) DO UPDATE SET
        \\  sessions_json = excluded.sessions_json,
        \\  updated_at = excluded.updated_at;
    ;
    const stmt = self.prepare(sql) catch |err| return ffi.errorFrom("prepare save sessions", err);
    defer _ = sqlite3_finalize(stmt);
    if (bindText(stmt, 1, workspace_path) != SQLITE_OK) return self.lastError();
    if (bindText(stmt, 2, sessions_json) != SQLITE_OK) return self.lastError();
    const rc = sqlite3_step(stmt);
    if (rc != SQLITE_DONE) return self.lastError();
    return ffi.errorSuccess();
}

fn ensureSchema(self: *Persistence) !void {
    const sql =
        \\CREATE TABLE IF NOT EXISTS workspace_sessions (
        \\  workspace_path TEXT PRIMARY KEY NOT NULL,
        \\  sessions_json TEXT NOT NULL,
        \\  updated_at INTEGER NOT NULL
        \\);
    ;
    var errmsg: ?[*:0]u8 = null;
    const rc = sqlite3_exec(self.db, sql, null, null, &errmsg);
    if (rc != SQLITE_OK) {
        if (errmsg) |msg| sqlite3_free(msg);
        return error.SchemaFailed;
    }
}

fn prepare(self: *Persistence, sql: [:0]const u8) !?*sqlite3_stmt {
    var stmt: ?*sqlite3_stmt = null;
    if (sqlite3_prepare_v2(self.db, sql.ptr, -1, &stmt, null) != SQLITE_OK) return error.PrepareFailed;
    return stmt;
}

fn bindText(stmt: ?*sqlite3_stmt, idx: c_int, value: []const u8) c_int {
    return sqlite3_bind_text(stmt, idx, value.ptr, @intCast(value.len), null);
}

fn lastError(self: *Persistence) structs.Error {
    const msg = std.mem.sliceTo(sqlite3_errmsg(self.db), 0);
    return ffi.errorMessage(1, msg);
}

fn isValidJsonArray(input: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, ffi.allocator, input, .{}) catch return false;
    defer parsed.deinit();
    return parsed.value == .array;
}

test "sqlite sessions round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = "sessions.sqlite";
    try tmp.dir.writeFile(.{ .sub_path = rel, .data = "" });
    const db_path = try tmp.dir.realpathAlloc(std.testing.allocator, rel);
    defer std.testing.allocator.free(db_path);

    var p = try Persistence.open(std.testing.allocator, db_path);
    defer p.close();
    const err = p.saveSessions("/tmp/repo", "[{\"id\":\"s1\"}]");
    defer ffi.errorFree(err);
    try std.testing.expectEqual(@as(i32, 0), err.code);
    const loaded = p.loadSessions("/tmp/repo");
    defer ffi.stringFree(loaded);
    try std.testing.expectEqualStrings("[{\"id\":\"s1\"}]", std.mem.sliceTo(loaded.ptr.?, 0));
}
