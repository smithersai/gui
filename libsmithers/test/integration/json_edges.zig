const std = @import("std");
const h = @import("helpers.zig");

fn makeLongEdgeJson(allocator: std.mem.Allocator) ![:0]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.writeAll("{\"model\":\"gpt-5-codex-\\u00e9\",\"text\":\"");
    for (0..1024 * 1024 + 17) |_| try out.writer.writeByte('x');
    try out.writer.writeAll("\",\"items\":[],\"optional\":null,\"unknown\":{\"future\":true,\"nested\":[]}}");
    return try out.toOwnedSliceSentinel(0);
}

test "client echo round-trips unicode long strings empty arrays nulls and unknown fields" {
    const long_json = try makeLongEdgeJson(std.testing.allocator);
    defer std.testing.allocator.free(long_json);

    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    var err: h.structs.Error = undefined;
    const result = h.embedded.smithers_client_call(client, "echo", long_json.ptr, &err);
    defer h.embedded.smithers_string_free(result);
    defer h.embedded.smithers_error_free(err);
    try h.expectSuccess(err);
    try std.testing.expectEqual(long_json.len, result.len);
    try std.testing.expect(std.mem.eql(u8, long_json, h.stringSlice(result)));

    var parsed = try h.expectJsonObject(h.stringSlice(result));
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expect(std.mem.indexOf(u8, obj.get("model").?.string, "\xc3\xa9") != null);
    try std.testing.expect(obj.get("text").?.string.len > 1024 * 1024);
    try std.testing.expectEqual(@as(usize, 0), obj.get("items").?.array.items.len);
    try std.testing.expect(obj.get("optional").? == .null);
    try std.testing.expect(obj.get("unknown").?.object.get("future").?.bool);
}

test "persistence preserves forward-compatible session JSON fields byte-for-byte" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "sessions.sqlite", .data = "" });
    const db_path = try h.tempPath(&tmp, "sessions.sqlite");
    defer std.testing.allocator.free(db_path);
    const db_z = try h.dupeZ(db_path);
    defer std.testing.allocator.free(db_z);

    const sessions =
        \\[{"id":"unicode","model":"gpt-5-\u2603","messages":[],"selected":null,"unknown":{"newField":true,"future":null}}]
    ;
    var open_err: h.structs.Error = undefined;
    const p = h.embedded.smithers_persistence_open(db_z.ptr, &open_err).?;
    defer h.embedded.smithers_persistence_close(p);
    defer h.embedded.smithers_error_free(open_err);
    try h.expectSuccess(open_err);

    const save_err = h.embedded.smithers_persistence_save_sessions(p, "/tmp/json-edge-workspace", sessions);
    defer h.embedded.smithers_error_free(save_err);
    try h.expectSuccess(save_err);

    const loaded = h.embedded.smithers_persistence_load_sessions(p, "/tmp/json-edge-workspace");
    defer h.embedded.smithers_string_free(loaded);
    try std.testing.expectEqualStrings(sessions, h.stringSlice(loaded));
}
