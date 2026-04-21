const std = @import("std");
const h = @import("helpers.zig");

test "persistence saves 100 sessions reopens and loads byte-for-byte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "sessions.sqlite", .data = "" });
    const db_path = try h.tempPath(&tmp, "sessions.sqlite");
    defer std.testing.allocator.free(db_path);
    const db_z = try h.dupeZ(db_path);
    defer std.testing.allocator.free(db_z);

    const workspace = "/tmp/smithers-persistence-roundtrip";
    const sessions_json = try h.makeSessionJson(std.testing.allocator, 100);
    defer std.testing.allocator.free(sessions_json);
    const sessions_z = try h.dupeZ(sessions_json);
    defer std.testing.allocator.free(sessions_z);

    var open_err: h.structs.Error = undefined;
    const p = h.embedded.smithers_persistence_open(db_z.ptr, &open_err).?;
    defer h.embedded.smithers_error_free(open_err);
    try h.expectSuccess(open_err);

    const save_err = h.embedded.smithers_persistence_save_sessions(p, workspace, sessions_z.ptr);
    defer h.embedded.smithers_error_free(save_err);
    try h.expectSuccess(save_err);
    h.embedded.smithers_persistence_close(p);

    var reopen_err: h.structs.Error = undefined;
    const reopened = h.embedded.smithers_persistence_open(db_z.ptr, &reopen_err).?;
    defer h.embedded.smithers_persistence_close(reopened);
    defer h.embedded.smithers_error_free(reopen_err);
    try h.expectSuccess(reopen_err);

    const loaded = h.embedded.smithers_persistence_load_sessions(reopened, workspace);
    defer h.embedded.smithers_string_free(loaded);
    try std.testing.expectEqualStrings(sessions_json, h.stringSlice(loaded));
}

const ThreadSaveState = struct {
    db_path: [*:0]const u8,
    workspace: [*:0]const u8,
    sessions_json: [*:0]const u8,
    code: i32 = -1,

    fn run(state: *ThreadSaveState) void {
        var open_err: h.structs.Error = undefined;
        const p = h.embedded.smithers_persistence_open(state.db_path, &open_err) orelse {
            state.code = open_err.code;
            h.embedded.smithers_error_free(open_err);
            return;
        };
        h.embedded.smithers_error_free(open_err);
        defer h.embedded.smithers_persistence_close(p);

        const save_err = h.embedded.smithers_persistence_save_sessions(p, state.workspace, state.sessions_json);
        state.code = save_err.code;
        h.embedded.smithers_error_free(save_err);
    }
};

test "persistence concurrent saves from two threads to same database do not corrupt rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "sessions.sqlite", .data = "" });
    const db_path = try h.tempPath(&tmp, "sessions.sqlite");
    defer std.testing.allocator.free(db_path);
    const db_z = try h.dupeZ(db_path);
    defer std.testing.allocator.free(db_z);

    const json_a = "[{\"id\":\"thread-a\",\"kind\":\"chat\"}]";
    const json_b = "[{\"id\":\"thread-b\",\"kind\":\"workflow\"}]";
    var state_a = ThreadSaveState{
        .db_path = db_z.ptr,
        .workspace = "/tmp/thread-a",
        .sessions_json = json_a,
    };
    var state_b = ThreadSaveState{
        .db_path = db_z.ptr,
        .workspace = "/tmp/thread-b",
        .sessions_json = json_b,
    };

    const thread_a = try std.Thread.spawn(.{}, ThreadSaveState.run, .{&state_a});
    const thread_b = try std.Thread.spawn(.{}, ThreadSaveState.run, .{&state_b});
    thread_a.join();
    thread_b.join();
    try std.testing.expectEqual(@as(i32, 0), state_a.code);
    try std.testing.expectEqual(@as(i32, 0), state_b.code);

    var open_err: h.structs.Error = undefined;
    const p = h.embedded.smithers_persistence_open(db_z.ptr, &open_err).?;
    defer h.embedded.smithers_persistence_close(p);
    defer h.embedded.smithers_error_free(open_err);
    try h.expectSuccess(open_err);

    const loaded_a = h.embedded.smithers_persistence_load_sessions(p, "/tmp/thread-a");
    defer h.embedded.smithers_string_free(loaded_a);
    const loaded_b = h.embedded.smithers_persistence_load_sessions(p, "/tmp/thread-b");
    defer h.embedded.smithers_string_free(loaded_b);
    try std.testing.expectEqualStrings(json_a, h.stringSlice(loaded_a));
    try std.testing.expectEqualStrings(json_b, h.stringSlice(loaded_b));
}
