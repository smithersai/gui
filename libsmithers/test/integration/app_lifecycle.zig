const std = @import("std");
const lib = @import("libsmithers");
const h = @import("helpers.zig");

const App = lib.App;
const Session = lib.session;
const structs = h.structs;

var lifecycle_state: ?*LifecycleState = null;

const LifecycleState = struct {
    changes: usize = 0,
    open_workspace: usize = 0,
    close_workspace: usize = 0,
    new_session: usize = 0,
    close_session: usize = 0,

    fn action(app_ptr: ?*anyopaque, target: structs.ActionTarget, act: structs.Action) callconv(.c) bool {
        _ = app_ptr;
        const state = lifecycle_state.?;
        switch (act.tag) {
            .open_workspace => {
                state.open_workspace += 1;
                std.testing.expect(target.tag == .app) catch unreachable;
                std.testing.expect(act.u.open_workspace.path != null) catch unreachable;
            },
            .close_workspace => {
                state.close_workspace += 1;
                std.testing.expect(target.tag == .app) catch unreachable;
            },
            .new_session => {
                state.new_session += 1;
                std.testing.expect(target.tag == .session) catch unreachable;
                std.testing.expect(target.u.session != null) catch unreachable;
            },
            .close_session => {
                state.close_session += 1;
                std.testing.expect(target.tag == .session) catch unreachable;
                std.testing.expect(act.u.close_session.session == target.u.session) catch unreachable;
            },
            else => {},
        }
        return true;
    }

    fn stateChanged(userdata: ?*anyopaque) callconv(.c) void {
        const state: *LifecycleState = @ptrCast(@alignCast(userdata.?));
        state.changes += 1;
    }
};

test "app lifecycle opens workspace creates session drains events and closes cleanly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("workspace");
    const workspace_path = try h.tempPath(&tmp, "workspace");
    defer std.testing.allocator.free(workspace_path);

    var state = LifecycleState{};
    lifecycle_state = &state;
    defer lifecycle_state = null;

    var app = try App.create(std.testing.allocator, .{
        .userdata = &state,
        .action = LifecycleState.action,
        .state_changed = LifecycleState.stateChanged,
    });
    defer app.destroy();

    const ws = try app.openWorkspace(workspace_path);
    const active_path = (try app.activeWorkspacePathDup(std.testing.allocator)).?;
    defer std.testing.allocator.free(active_path);
    try std.testing.expectEqualStrings(workspace_path, active_path);

    const session = try Session.create(app, .{ .kind = .chat, .target_id = "run-42" });
    const stream = session.events();
    defer stream.destroy();
    session.sendText("/runs status=active");
    const ev = stream.next();
    defer h.ffi.stringFree(ev.payload);
    try std.testing.expectEqual(structs.EventTag.json, ev.tag);
    try h.expectJsonValid(h.stringSlice(ev.payload));

    const none = stream.next();
    defer h.ffi.stringFree(none.payload);
    try std.testing.expectEqual(structs.EventTag.none, none.tag);

    session.destroy();
    app.closeWorkspace(ws);

    try std.testing.expectEqual(@as(usize, 1), state.open_workspace);
    try std.testing.expectEqual(@as(usize, 1), state.new_session);
    try std.testing.expectEqual(@as(usize, 1), state.close_session);
    try std.testing.expectEqual(@as(usize, 1), state.close_workspace);
    try std.testing.expect(state.changes >= 4);
}

test "multiple embedded apps in sequence keep independent workspace state" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("one");
    try tmp.dir.makeDir("two");
    const paths = [_][]const u8{
        try h.tempPath(&tmp, "one"),
        try h.tempPath(&tmp, "two"),
    };
    defer for (paths) |path| std.testing.allocator.free(path);

    for (paths, 0..) |path, i| {
        const path_z = try h.dupeZ(path);
        defer std.testing.allocator.free(path_z);

        const app = h.embedded.smithers_app_new(null).?;
        const ws = h.embedded.smithers_app_open_workspace(app, path_z.ptr).?;
        const active = h.embedded.smithers_app_active_workspace_path(app);
        defer h.embedded.smithers_string_free(active);
        try std.testing.expectEqualStrings(path, h.stringSlice(active));

        const session = h.embedded.smithers_session_new(app, .{
            .kind = .dashboard,
            .target_id = if (i == 0) "first" else "second",
        }).?;
        h.embedded.smithers_session_free(session);
        h.embedded.smithers_app_close_workspace(app, ws);
        h.embedded.smithers_app_free(app);
    }
}
