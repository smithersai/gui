const std = @import("std");
const h = @import("helpers.zig");

test "workspace roundtrip tracks active path and recents order across two roots" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("repo-a");
    try tmp.dir.makeDir("repo-b");
    const path_a = try h.tempPath(&tmp, "repo-a");
    defer std.testing.allocator.free(path_a);
    const path_b = try h.tempPath(&tmp, "repo-b");
    defer std.testing.allocator.free(path_b);
    const path_a_z = try h.dupeZ(path_a);
    defer std.testing.allocator.free(path_a_z);
    const path_b_z = try h.dupeZ(path_b);
    defer std.testing.allocator.free(path_b_z);

    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);

    const ws_a = h.embedded.smithers_app_open_workspace(app, path_a_z.ptr).?;
    const session_a = h.embedded.smithers_session_new(app, .{
        .kind = .workflow,
        .workspace_path = path_a_z.ptr,
        .target_id = "workflow-a",
    }).?;
    defer h.embedded.smithers_session_free(session_a);

    const ws_b = h.embedded.smithers_app_open_workspace(app, path_b_z.ptr).?;
    const active_b = h.embedded.smithers_app_active_workspace_path(app);
    defer h.embedded.smithers_string_free(active_b);
    try std.testing.expectEqualStrings(path_b, h.stringSlice(active_b));

    const recents = h.embedded.smithers_app_recent_workspaces_json(app);
    defer h.embedded.smithers_string_free(recents);
    var parsed = try h.expectJsonArray(h.stringSlice(recents));
    defer parsed.deinit();
    try std.testing.expect(parsed.value.array.items.len >= 2);
    const first = parsed.value.array.items[0].object.get("path").?.string;
    const second = parsed.value.array.items[1].object.get("path").?.string;
    try std.testing.expectEqualStrings(path_b, first);
    try std.testing.expectEqualStrings(path_a, second);

    h.embedded.smithers_app_close_workspace(app, ws_a);
    const still_active = h.embedded.smithers_app_active_workspace_path(app);
    defer h.embedded.smithers_string_free(still_active);
    try std.testing.expectEqualStrings(path_b, h.stringSlice(still_active));

    h.embedded.smithers_app_close_workspace(app, ws_b);
    const none_active = h.embedded.smithers_app_active_workspace_path(app);
    defer h.embedded.smithers_string_free(none_active);
    try std.testing.expectEqualStrings("", h.stringSlice(none_active));
}

test "reopening an existing workspace moves it to the front without duplicating recent entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("repo-a");
    try tmp.dir.makeDir("repo-b");
    const path_a = try h.tempPath(&tmp, "repo-a");
    defer std.testing.allocator.free(path_a);
    const path_b = try h.tempPath(&tmp, "repo-b");
    defer std.testing.allocator.free(path_b);
    const path_a_z = try h.dupeZ(path_a);
    defer std.testing.allocator.free(path_a_z);
    const path_b_z = try h.dupeZ(path_b);
    defer std.testing.allocator.free(path_b_z);

    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const ws_a = h.embedded.smithers_app_open_workspace(app, path_a_z.ptr).?;
    const ws_b = h.embedded.smithers_app_open_workspace(app, path_b_z.ptr).?;
    const ws_a_again = h.embedded.smithers_app_open_workspace(app, path_a_z.ptr).?;
    try std.testing.expectEqual(ws_a, ws_a_again);

    const recents = h.embedded.smithers_app_recent_workspaces_json(app);
    defer h.embedded.smithers_string_free(recents);
    var parsed = try h.expectJsonArray(h.stringSlice(recents));
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expectEqualStrings(path_a, parsed.value.array.items[0].object.get("path").?.string);
    try std.testing.expectEqualStrings(path_b, parsed.value.array.items[1].object.get("path").?.string);

    h.embedded.smithers_app_close_workspace(app, ws_a);
    h.embedded.smithers_app_close_workspace(app, ws_b);
}
