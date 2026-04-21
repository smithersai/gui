const std = @import("std");
const lib = @import("libsmithers");

const embedded = lib.apprt.embedded;
const structs = lib.apprt.structs;
const ffi = lib.ffi;

fn expectJsonValid(s: structs.String) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, std.mem.sliceTo(s.ptr.?, 0), .{});
    parsed.deinit();
}

test "top-level init info and primitive frees" {
    try std.testing.expectEqual(@as(i32, 0), embedded.smithers_init(0, null));
    const info = embedded.smithers_info();
    try std.testing.expectEqualStrings("0.1.0", std.mem.sliceTo(info.version, 0));
    try std.testing.expect(info.platform != .invalid);

    const s = ffi.stringDup("owned");
    embedded.smithers_string_free(s);
    const e = ffi.errorMessage(9, "owned error");
    embedded.smithers_error_free(e);
    const b = ffi.bytesDup("abc");
    embedded.smithers_bytes_free(b);
}

test "app workspace lifecycle and callbacks" {
    const State = struct {
        wakeups: usize = 0,
        actions: usize = 0,
        changes: usize = 0,

        fn wakeup(userdata: ?*anyopaque) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(userdata.?));
            state.wakeups += 1;
        }

        fn action(_: ?*anyopaque, _: structs.ActionTarget, act: structs.Action) callconv(.c) bool {
            _ = act;
            return true;
        }

        fn stateChanged(userdata: ?*anyopaque) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(userdata.?));
            state.changes += 1;
        }
    };

    var state = State{};
    const cfg = structs.RuntimeConfig{
        .userdata = &state,
        .wakeup = State.wakeup,
        .action = State.action,
        .state_changed = State.stateChanged,
    };
    const app = embedded.smithers_app_new(&cfg).?;
    defer embedded.smithers_app_free(app);

    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&state)), embedded.smithers_app_userdata(app));
    embedded.smithers_app_tick(app);
    embedded.smithers_app_set_color_scheme(app, .dark);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);

    const ws = embedded.smithers_app_open_workspace(app, path_z.ptr).?;
    const active = embedded.smithers_app_active_workspace_path(app);
    defer embedded.smithers_string_free(active);
    try std.testing.expectEqualStrings(path, std.mem.sliceTo(active.ptr.?, 0));

    const recents = embedded.smithers_app_recent_workspaces_json(app);
    defer embedded.smithers_string_free(recents);
    try expectJsonValid(recents);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(recents.ptr.?, 0), path) != null);

    embedded.smithers_app_close_workspace(app, ws);
    try std.testing.expect(state.changes >= 2);
}

test "session lifecycle send text and events" {
    const app = embedded.smithers_app_new(null).?;
    defer embedded.smithers_app_free(app);
    const opts = structs.SessionOptions{
        .kind = .chat,
        .target_id = "run-1",
        .userdata = @ptrFromInt(0x1234),
    };
    const session = embedded.smithers_session_new(app, opts).?;
    defer embedded.smithers_session_free(session);

    try std.testing.expectEqual(structs.SessionKind.chat, embedded.smithers_session_kind(session));
    try std.testing.expectEqual(@as(?*anyopaque, @ptrFromInt(0x1234)), embedded.smithers_session_userdata(session));

    const title = embedded.smithers_session_title(session);
    defer embedded.smithers_string_free(title);
    try std.testing.expectEqualStrings("Chat run-1", std.mem.sliceTo(title.ptr.?, 0));

    const text = "/runs status=active";
    embedded.smithers_session_send_text(session, text.ptr, text.len);
    const stream = embedded.smithers_session_events(session).?;
    defer embedded.smithers_event_stream_free(stream);
    const ev = embedded.smithers_event_stream_next(stream);
    defer embedded.smithers_event_free(ev);
    try std.testing.expectEqual(structs.EventTag.json, ev.tag);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(ev.payload.ptr.?, 0), "slashCommand") != null);
}

test "client call and stream mock daemon fixtures" {
    const app = embedded.smithers_app_new(null).?;
    defer embedded.smithers_app_free(app);
    const client = embedded.smithers_client_new(app).?;
    defer embedded.smithers_client_free(client);

    var err: structs.Error = undefined;
    const result = embedded.smithers_client_call(client, "listRuns", "{\"mockResult\":[{\"runId\":\"run-1\"}]}", &err);
    defer embedded.smithers_string_free(result);
    defer embedded.smithers_error_free(err);
    try std.testing.expectEqual(@as(i32, 0), err.code);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.sliceTo(result.ptr.?, 0), "run-1") != null);

    var stream_err: structs.Error = undefined;
    const stream = embedded.smithers_client_stream(client, "streamChat", "{\"events\":[{\"token\":\"a\"},{\"token\":\"b\"}]}", &stream_err).?;
    defer embedded.smithers_event_stream_free(stream);
    defer embedded.smithers_error_free(stream_err);
    const first = embedded.smithers_event_stream_next(stream);
    defer embedded.smithers_event_free(first);
    const second = embedded.smithers_event_stream_next(stream);
    defer embedded.smithers_event_free(second);
    const end = embedded.smithers_event_stream_next(stream);
    defer embedded.smithers_event_free(end);
    try std.testing.expectEqual(structs.EventTag.json, first.tag);
    try std.testing.expectEqual(structs.EventTag.json, second.tag);
    try std.testing.expectEqual(structs.EventTag.end, end.tag);
}

test "slash parse and palette scoring golden cases" {
    const parsed = embedded.smithers_slashcmd_parse("/workflow:ship env=\"prod west\" dry=true");
    defer embedded.smithers_string_free(parsed);
    const parsed_text = std.mem.sliceTo(parsed.ptr.?, 0);
    try std.testing.expect(std.mem.indexOf(u8, parsed_text, "workflow:ship") != null);
    try std.testing.expect(std.mem.indexOf(u8, parsed_text, "prod west") != null);

    const app = embedded.smithers_app_new(null).?;
    defer embedded.smithers_app_free(app);
    const palette = embedded.smithers_palette_new(app).?;
    defer embedded.smithers_palette_free(palette);
    embedded.smithers_palette_set_mode(palette, .commands);
    embedded.smithers_palette_set_query(palette, "terminal");
    const items = embedded.smithers_palette_items_json(palette);
    defer embedded.smithers_string_free(items);
    try expectJsonValid(items);
    const text = std.mem.sliceTo(items.ptr.?, 0);
    try std.testing.expect(std.mem.indexOf(u8, text, "New Terminal Workspace") != null);

    const activation = embedded.smithers_palette_activate(palette, "command.new-terminal");
    defer embedded.smithers_error_free(activation);
    try std.testing.expectEqual(@as(i32, 0), activation.code);
}

test "cwd resolver edge cases" {
    const home = embedded.smithers_cwd_resolve("/");
    defer embedded.smithers_string_free(home);
    try std.testing.expect(std.mem.eql(u8, std.mem.sliceTo(home.ptr.?, 0), std.posix.getenv("HOME") orelse ""));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);

    const resolved = embedded.smithers_cwd_resolve(path_z.ptr);
    defer embedded.smithers_string_free(resolved);
    try std.testing.expectEqualStrings(path, std.mem.sliceTo(resolved.ptr.?, 0));
}

test "SQLite persistence JSON round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "sessions.sqlite", .data = "" });
    const db_path = try tmp.dir.realpathAlloc(std.testing.allocator, "sessions.sqlite");
    defer std.testing.allocator.free(db_path);
    const db_z = try std.testing.allocator.dupeZ(u8, db_path);
    defer std.testing.allocator.free(db_z);

    var open_err: structs.Error = undefined;
    const p = embedded.smithers_persistence_open(db_z.ptr, &open_err).?;
    defer embedded.smithers_persistence_close(p);
    defer embedded.smithers_error_free(open_err);

    const save_err = embedded.smithers_persistence_save_sessions(p, "/tmp/repo", "[{\"id\":\"s1\",\"kind\":\"chat\"}]");
    defer embedded.smithers_error_free(save_err);
    try std.testing.expectEqual(@as(i32, 0), save_err.code);

    const loaded = embedded.smithers_persistence_load_sessions(p, "/tmp/repo");
    defer embedded.smithers_string_free(loaded);
    try std.testing.expectEqualStrings("[{\"id\":\"s1\",\"kind\":\"chat\"}]", std.mem.sliceTo(loaded.ptr.?, 0));
}

test "SmithersModels and app Models samples round trip as JSON" {
    inline for (lib.models.smithers_model_descriptors) |descriptor| {
        const out = try lib.models.roundTripJson(std.testing.allocator, descriptor.name, descriptor.sample_json);
        defer std.testing.allocator.free(out);
        try std.testing.expect(out.len > 0);
    }
    inline for (lib.models.app.app_model_descriptors) |descriptor| {
        const out = try lib.models.roundTripJson(std.testing.allocator, descriptor.name, descriptor.sample_json);
        defer std.testing.allocator.free(out);
        try std.testing.expect(out.len > 0);
    }
}

test "action tag union converts to C tag" {
    var c = try (lib.apprt.action.Action{ .open_workspace = "/tmp/repo" }).cvalAlloc(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(structs.ActionTag.open_workspace, c.action.tag);
    try std.testing.expectEqualStrings("/tmp/repo", std.mem.sliceTo(c.action.u.open_workspace.path.?, 0));

    const target = (lib.apprt.action.Target{ .app = @ptrFromInt(0x9999) }).cval();
    try std.testing.expectEqual(structs.ActionTargetTag.app, target.tag);
}
