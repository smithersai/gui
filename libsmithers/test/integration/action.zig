const std = @import("std");
const lib = @import("libsmithers");
const h = @import("helpers.zig");

const App = lib.App;
const action = lib.apprt.action;
const tag_count = @intFromEnum(h.structs.ActionTag._max);

var action_state: ?*ActionState = null;

const ActionState = struct {
    app_ptr: ?*anyopaque = null,
    session_ptr: ?*anyopaque = @ptrFromInt(0x1234),
    seen: [tag_count]bool = [_]bool{false} ** tag_count,

    fn callback(app_ptr: ?*anyopaque, target: h.structs.ActionTarget, act: h.structs.Action) callconv(.c) bool {
        const state = action_state.?;
        std.testing.expectEqual(state.app_ptr, app_ptr) catch unreachable;
        const index: usize = @intCast(@intFromEnum(act.tag));
        if (index < state.seen.len) state.seen[index] = true;

        switch (act.tag) {
            .none, .close_workspace, .new_session, .focus_session, .present_command_palette, .dismiss_command_palette, .config_changed => {
                std.testing.expectEqual(h.structs.ActionTargetTag.app, target.tag) catch unreachable;
                std.testing.expectEqual(state.app_ptr, target.u.app) catch unreachable;
            },
            .open_workspace => {
                std.testing.expectEqual(h.structs.ActionTargetTag.app, target.tag) catch unreachable;
                std.testing.expectEqualStrings("/tmp/action-workspace", std.mem.sliceTo(act.u.open_workspace.path.?, 0)) catch unreachable;
            },
            .close_session => {
                std.testing.expectEqual(h.structs.ActionTargetTag.session, target.tag) catch unreachable;
                std.testing.expectEqual(state.session_ptr, target.u.session) catch unreachable;
                std.testing.expectEqual(state.session_ptr, act.u.close_session.session) catch unreachable;
            },
            .show_toast => {
                std.testing.expectEqualStrings("Saved", std.mem.sliceTo(act.u.toast.title.?, 0)) catch unreachable;
                std.testing.expectEqualStrings("Workflow saved", std.mem.sliceTo(act.u.toast.body.?, 0)) catch unreachable;
                std.testing.expectEqual(@as(i32, 2), act.u.toast.kind) catch unreachable;
            },
            .desktop_notify => {
                std.testing.expectEqualStrings("Run finished", std.mem.sliceTo(act.u.desktop_notify.title.?, 0)) catch unreachable;
                std.testing.expectEqualStrings("run-1 completed", std.mem.sliceTo(act.u.desktop_notify.body.?, 0)) catch unreachable;
            },
            .run_started, .run_finished, .run_state_changed, .approval_requested => {
                std.testing.expectEqualStrings("run-1", std.mem.sliceTo(act.u.run_event.run_id.?, 0)) catch unreachable;
            },
            .clipboard_write => {
                std.testing.expectEqualStrings("copy me", std.mem.sliceTo(act.u.clipboard_write.text.?, 0)) catch unreachable;
            },
            .open_url => {
                std.testing.expectEqualStrings("https://smithers.sh/run/run-1", std.mem.sliceTo(act.u.open_url.url.?, 0)) catch unreachable;
            },
            ._max => unreachable,
        }
        return true;
    }
};

test "action callback trampoline delivers every action tag and payload" {
    var state = ActionState{};
    action_state = &state;
    defer action_state = null;

    var app = try App.create(std.testing.allocator, .{ .action = ActionState.callback });
    defer app.destroy();
    state.app_ptr = app;

    const app_target = action.Target{ .app = app };
    const session_target = action.Target{ .session = state.session_ptr };

    try std.testing.expect(app.performAction(app_target, .none));
    try std.testing.expect(app.performAction(app_target, .{ .open_workspace = "/tmp/action-workspace" }));
    try std.testing.expect(app.performAction(app_target, .close_workspace));
    try std.testing.expect(app.performAction(app_target, .new_session));
    try std.testing.expect(app.performAction(session_target, .{ .close_session = state.session_ptr }));
    try std.testing.expect(app.performAction(app_target, .focus_session));
    try std.testing.expect(app.performAction(app_target, .present_command_palette));
    try std.testing.expect(app.performAction(app_target, .dismiss_command_palette));
    try std.testing.expect(app.performAction(app_target, .{ .show_toast = .{ .title = "Saved", .body = "Workflow saved", .kind = 2 } }));
    try std.testing.expect(app.performAction(app_target, .{ .desktop_notify = .{ .title = "Run finished", .body = "run-1 completed" } }));
    try std.testing.expect(app.performAction(app_target, .{ .run_started = "run-1" }));
    try std.testing.expect(app.performAction(app_target, .{ .run_finished = "run-1" }));
    try std.testing.expect(app.performAction(app_target, .{ .run_state_changed = "run-1" }));
    try std.testing.expect(app.performAction(app_target, .{ .approval_requested = "run-1" }));
    try std.testing.expect(app.performAction(app_target, .{ .clipboard_write = "copy me" }));
    try std.testing.expect(app.performAction(app_target, .{ .open_url = "https://smithers.sh/run/run-1" }));
    try std.testing.expect(app.performAction(app_target, .config_changed));

    for (state.seen, 0..) |seen, index| {
        try std.testing.expect(seen);
        try std.testing.expect(index < tag_count);
    }
}
