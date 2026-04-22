const std = @import("std");
const lib = @import("libsmithers");
const h = @import("helpers.zig");

const App = lib.App;
const Session = lib.session;

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

test "recent workspaces persist across app restarts via sqlite" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("repo-a");
    try tmp.dir.makeDir("repo-b");
    try tmp.dir.writeFile(.{ .sub_path = "app.sqlite", .data = "" });

    const path_a = try h.tempPath(&tmp, "repo-a");
    defer std.testing.allocator.free(path_a);
    const path_b = try h.tempPath(&tmp, "repo-b");
    defer std.testing.allocator.free(path_b);
    const db_path = try h.tempPath(&tmp, "app.sqlite");
    defer std.testing.allocator.free(db_path);

    const path_a_z = try h.dupeZ(path_a);
    defer std.testing.allocator.free(path_a_z);
    const path_b_z = try h.dupeZ(path_b);
    defer std.testing.allocator.free(path_b_z);
    const db_z = try h.dupeZ(db_path);
    defer std.testing.allocator.free(db_z);

    const cfg_1 = h.structs.RuntimeConfig{ .recents_db_path = db_z.ptr };
    const app_1 = h.embedded.smithers_app_new(&cfg_1).?;
    _ = h.embedded.smithers_app_open_workspace(app_1, path_a_z.ptr).?;
    _ = h.embedded.smithers_app_open_workspace(app_1, path_b_z.ptr).?;
    h.embedded.smithers_app_free(app_1);

    const cfg_2 = h.structs.RuntimeConfig{ .recents_db_path = db_z.ptr };
    const app_2 = h.embedded.smithers_app_new(&cfg_2).?;
    defer h.embedded.smithers_app_free(app_2);

    const recents = h.embedded.smithers_app_recent_workspaces_json(app_2);
    defer h.embedded.smithers_string_free(recents);
    var parsed = try h.expectJsonArray(h.stringSlice(recents));
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.array.items.len);
    try std.testing.expectEqualStrings(path_b, parsed.value.array.items[0].object.get("path").?.string);
    try std.testing.expectEqualStrings(path_a, parsed.value.array.items[1].object.get("path").?.string);
}

test "remove recent workspace persists across app restarts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("repo-a");
    try tmp.dir.makeDir("repo-b");
    try tmp.dir.writeFile(.{ .sub_path = "app.sqlite", .data = "" });

    const path_a = try h.tempPath(&tmp, "repo-a");
    defer std.testing.allocator.free(path_a);
    const path_b = try h.tempPath(&tmp, "repo-b");
    defer std.testing.allocator.free(path_b);
    const db_path = try h.tempPath(&tmp, "app.sqlite");
    defer std.testing.allocator.free(db_path);

    const path_a_z = try h.dupeZ(path_a);
    defer std.testing.allocator.free(path_a_z);
    const path_b_z = try h.dupeZ(path_b);
    defer std.testing.allocator.free(path_b_z);
    const db_z = try h.dupeZ(db_path);
    defer std.testing.allocator.free(db_z);

    const cfg_1 = h.structs.RuntimeConfig{ .recents_db_path = db_z.ptr };
    const app_1 = h.embedded.smithers_app_new(&cfg_1).?;
    _ = h.embedded.smithers_app_open_workspace(app_1, path_a_z.ptr).?;
    _ = h.embedded.smithers_app_open_workspace(app_1, path_b_z.ptr).?;
    h.embedded.smithers_app_remove_recent_workspace(app_1, path_a_z.ptr);
    h.embedded.smithers_app_free(app_1);

    const cfg_2 = h.structs.RuntimeConfig{ .recents_db_path = db_z.ptr };
    const app_2 = h.embedded.smithers_app_new(&cfg_2).?;
    defer h.embedded.smithers_app_free(app_2);

    const recents = h.embedded.smithers_app_recent_workspaces_json(app_2);
    defer h.embedded.smithers_string_free(recents);
    var parsed = try h.expectJsonArray(h.stringSlice(recents));
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    try std.testing.expectEqualStrings(path_b, parsed.value.array.items[0].object.get("path").?.string);
}

test "reopening a persisted workspace restores chat sessions and replays their history" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("repo");
    try tmp.dir.writeFile(.{ .sub_path = "app.sqlite", .data = "" });

    const workspace_path = try h.tempPath(&tmp, "repo");
    defer std.testing.allocator.free(workspace_path);
    const workspace_path_z = try h.dupeZ(workspace_path);
    defer std.testing.allocator.free(workspace_path_z);
    const db_path = try h.tempPath(&tmp, "app.sqlite");
    defer std.testing.allocator.free(db_path);
    const db_z = try h.dupeZ(db_path);
    defer std.testing.allocator.free(db_z);

    {
        var app = try App.create(std.testing.allocator, .{
            .recents_db_path = db_z.ptr,
        });
        defer app.destroy();

        _ = try app.openWorkspace(workspace_path);
        const chat = try Session.create(app, .{
            .kind = .chat,
            .workspace_path = workspace_path_z.ptr,
        });
        defer chat.destroy();

        chat.sendText("Reopen should keep this chat history");
        try std.testing.expectEqual(@as(usize, 1), app.sessions.items.len);
    }

    {
        var app = try App.create(std.testing.allocator, .{
            .recents_db_path = db_z.ptr,
        });
        defer app.destroy();

        _ = try app.openWorkspace(workspace_path);
        app.tick();
        try std.testing.expectEqual(@as(usize, 1), app.sessions.items.len);

        const restored = app.sessions.items[0];
        try std.testing.expectEqual(h.structs.SessionKind.chat, restored.kind());

        const stream = restored.events();
        defer stream.destroy();

        const first = stream.next();
        defer h.embedded.smithers_event_free(first);
        try std.testing.expectEqual(h.structs.EventTag.json, first.tag);

        var parsed = try h.expectJsonObject(h.stringSlice(first.payload));
        defer parsed.deinit();
        try std.testing.expectEqualStrings("user", parsed.value.object.get("role").?.string);
        try std.testing.expectEqualStrings(
            "Reopen should keep this chat history",
            parsed.value.object.get("content").?.string,
        );
    }
}

test "chat session persistence does not overwrite existing workspace session blobs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("repo");
    try tmp.dir.writeFile(.{ .sub_path = "app.sqlite", .data = "" });

    const workspace_path = try h.tempPath(&tmp, "repo");
    defer std.testing.allocator.free(workspace_path);
    const workspace_path_z = try h.dupeZ(workspace_path);
    defer std.testing.allocator.free(workspace_path_z);
    const db_path = try h.tempPath(&tmp, "app.sqlite");
    defer std.testing.allocator.free(db_path);
    const db_z = try h.dupeZ(db_path);
    defer std.testing.allocator.free(db_z);

    const legacy_sessions_json =
        "[{\"kind\":\"terminal\",\"terminalTab\":{\"terminalId\":\"term-1\",\"title\":\"Shell\"}}]";

    {
        var open_err: h.structs.Error = undefined;
        const persistence = h.embedded.smithers_persistence_open(db_z.ptr, &open_err).?;
        defer h.embedded.smithers_persistence_close(persistence);
        defer h.embedded.smithers_error_free(open_err);
        try h.expectSuccess(open_err);

        const save_err = h.embedded.smithers_persistence_save_sessions(
            persistence,
            workspace_path_z.ptr,
            legacy_sessions_json,
        );
        defer h.embedded.smithers_error_free(save_err);
        try h.expectSuccess(save_err);
    }

    {
        var app = try App.create(std.testing.allocator, .{
            .recents_db_path = db_z.ptr,
        });
        defer app.destroy();

        _ = try app.openWorkspace(workspace_path);
        const chat = try Session.create(app, .{
            .kind = .chat,
            .workspace_path = workspace_path_z.ptr,
        });
        defer chat.destroy();

        chat.sendText("Keep legacy workspace session blobs intact");
    }

    {
        var open_err: h.structs.Error = undefined;
        const persistence = h.embedded.smithers_persistence_open(db_z.ptr, &open_err).?;
        defer h.embedded.smithers_persistence_close(persistence);
        defer h.embedded.smithers_error_free(open_err);
        try h.expectSuccess(open_err);

        const loaded = h.embedded.smithers_persistence_load_sessions(persistence, workspace_path_z.ptr);
        defer h.embedded.smithers_string_free(loaded);
        try std.testing.expectEqualStrings(legacy_sessions_json, h.stringSlice(loaded));
    }

    {
        var app = try App.create(std.testing.allocator, .{
            .recents_db_path = db_z.ptr,
        });
        defer app.destroy();

        _ = try app.openWorkspace(workspace_path);
        app.tick();
        try std.testing.expectEqual(@as(usize, 1), app.sessions.items.len);

        const restored = app.sessions.items[0];
        const stream = restored.events();
        defer stream.destroy();

        const first = stream.next();
        defer h.embedded.smithers_event_free(first);
        try std.testing.expectEqual(h.structs.EventTag.json, first.tag);
        var parsed = try h.expectJsonObject(h.stringSlice(first.payload));
        defer parsed.deinit();
        try std.testing.expectEqualStrings(
            "Keep legacy workspace session blobs intact",
            parsed.value.object.get("content").?.string,
        );
    }
}
