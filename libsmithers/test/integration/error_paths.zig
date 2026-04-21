const std = @import("std");
const h = @import("helpers.zig");

test "client call out_err is set on failure cleared on success and free is safe" {
    h.embedded.smithers_error_free(.{ .code = 0, .msg = null });

    var null_err: h.structs.Error = undefined;
    const null_result = h.embedded.smithers_client_call(null, "listRuns", "{}", &null_err);
    defer h.embedded.smithers_string_free(null_result);
    defer h.embedded.smithers_error_free(null_err);
    try h.expectError(null_err, 1, "client is null");
    try std.testing.expectEqualStrings("null", h.stringSlice(null_result));

    const ignored_err_result = h.embedded.smithers_client_call(null, "listRuns", "{}", null);
    defer h.embedded.smithers_string_free(ignored_err_result);
    try std.testing.expectEqualStrings("null", h.stringSlice(ignored_err_result));

    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    var invalid_err: h.structs.Error = undefined;
    const invalid = h.embedded.smithers_client_call(client, "listRuns", "{not-json", &invalid_err);
    defer h.embedded.smithers_string_free(invalid);
    defer h.embedded.smithers_error_free(invalid_err);
    try std.testing.expect(invalid_err.code != 0);
    try std.testing.expect(std.mem.indexOf(u8, h.errorMessageSlice(invalid_err), "client call") != null);

    var success_err = h.structs.Error{ .code = 123, .msg = null };
    const success = h.embedded.smithers_client_call(client, "listRuns", "{\"mockResult\":[]}", &success_err);
    defer h.embedded.smithers_string_free(success);
    defer h.embedded.smithers_error_free(success_err);
    try h.expectSuccess(success_err);
    try std.testing.expectEqualStrings("[]", h.stringSlice(success));
}

test "client stream out_err is set on failure cleared on success and stream free is safe" {
    var null_err: h.structs.Error = undefined;
    const missing = h.embedded.smithers_client_stream(null, "streamChat", "{}", &null_err);
    defer h.embedded.smithers_error_free(null_err);
    try std.testing.expect(missing == null);
    try h.expectError(null_err, 1, "client is null");

    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    var invalid_err: h.structs.Error = undefined;
    const invalid = h.embedded.smithers_client_stream(client, "streamChat", "{not-json", &invalid_err);
    defer h.embedded.smithers_error_free(invalid_err);
    try std.testing.expect(invalid == null);
    try std.testing.expect(invalid_err.code != 0);

    var success_err = h.structs.Error{ .code = 123, .msg = null };
    const stream = h.embedded.smithers_client_stream(client, "streamChat", "{\"events\":[]}", &success_err).?;
    defer h.embedded.smithers_event_stream_free(stream);
    defer h.embedded.smithers_error_free(success_err);
    try h.expectSuccess(success_err);
    const end = h.embedded.smithers_event_stream_next(stream);
    defer h.embedded.smithers_event_free(end);
    try std.testing.expectEqual(h.structs.EventTag.end, end.tag);
}

test "persistence open out_err is set on failure cleared on success and save errors are owned" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try h.tempPath(&tmp, ".");
    defer std.testing.allocator.free(root);
    const missing_parent_path = try std.fs.path.join(std.testing.allocator, &.{ root, "missing", "sessions.sqlite" });
    defer std.testing.allocator.free(missing_parent_path);
    const missing_z = try h.dupeZ(missing_parent_path);
    defer std.testing.allocator.free(missing_z);

    var open_fail: h.structs.Error = undefined;
    const failed = h.embedded.smithers_persistence_open(missing_z.ptr, &open_fail);
    defer h.embedded.smithers_error_free(open_fail);
    try std.testing.expect(failed == null);
    try std.testing.expect(open_fail.code != 0);

    try tmp.dir.writeFile(.{ .sub_path = "sessions.sqlite", .data = "" });
    const db_path = try h.tempPath(&tmp, "sessions.sqlite");
    defer std.testing.allocator.free(db_path);
    const db_z = try h.dupeZ(db_path);
    defer std.testing.allocator.free(db_z);

    var open_ok = h.structs.Error{ .code = 99, .msg = null };
    const p = h.embedded.smithers_persistence_open(db_z.ptr, &open_ok).?;
    defer h.embedded.smithers_persistence_close(p);
    defer h.embedded.smithers_error_free(open_ok);
    try h.expectSuccess(open_ok);

    const save_fail = h.embedded.smithers_persistence_save_sessions(p, "/tmp/workspace", "{\"not\":\"array\"}");
    defer h.embedded.smithers_error_free(save_fail);
    try h.expectError(save_fail, 2, "JSON array");

    const save_ok = h.embedded.smithers_persistence_save_sessions(p, "/tmp/workspace", "[]");
    defer h.embedded.smithers_error_free(save_ok);
    try h.expectSuccess(save_ok);
}
