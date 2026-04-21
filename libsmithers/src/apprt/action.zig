const std = @import("std");
const structs = @import("structs.zig");

pub const Target = union(enum) {
    app: ?*anyopaque,
    session: ?*anyopaque,

    pub fn cval(self: Target) structs.ActionTarget {
        return switch (self) {
            .app => |ptr| .{ .tag = .app, .u = .{ .app = ptr } },
            .session => |ptr| .{ .tag = .session, .u = .{ .session = ptr } },
        };
    }
};

pub const Action = union(structs.ActionTag) {
    none,
    open_workspace: []const u8,
    close_workspace,
    new_session,
    close_session: ?*anyopaque,
    focus_session,
    present_command_palette,
    dismiss_command_palette,
    show_toast: Toast,
    desktop_notify: DesktopNotification,
    run_started: []const u8,
    run_finished: []const u8,
    run_state_changed: []const u8,
    approval_requested: []const u8,
    clipboard_write: []const u8,
    open_url: []const u8,
    config_changed,
    _max,

    pub const Toast = struct {
        title: []const u8,
        body: []const u8,
        kind: i32 = 0,
    };

    pub const DesktopNotification = struct {
        title: []const u8,
        body: []const u8,
    };

    pub fn cval(self: Action) structs.Action {
        return switch (self) {
            .none => .{ .tag = .none, .u = .{ ._reserved = zeroes() } },
            .open_workspace => |path| .{ .tag = .open_workspace, .u = .{ .open_workspace = .{ .path = sentinel(path) } } },
            .close_workspace => .{ .tag = .close_workspace, .u = .{ ._reserved = zeroes() } },
            .new_session => .{ .tag = .new_session, .u = .{ ._reserved = zeroes() } },
            .close_session => |session| .{ .tag = .close_session, .u = .{ .close_session = .{ .session = session } } },
            .focus_session => .{ .tag = .focus_session, .u = .{ ._reserved = zeroes() } },
            .present_command_palette => .{ .tag = .present_command_palette, .u = .{ ._reserved = zeroes() } },
            .dismiss_command_palette => .{ .tag = .dismiss_command_palette, .u = .{ ._reserved = zeroes() } },
            .show_toast => |toast| .{ .tag = .show_toast, .u = .{ .toast = .{
                .title = sentinel(toast.title),
                .body = sentinel(toast.body),
                .kind = toast.kind,
            } } },
            .desktop_notify => |n| .{ .tag = .desktop_notify, .u = .{ .desktop_notify = .{
                .title = sentinel(n.title),
                .body = sentinel(n.body),
            } } },
            .run_started => |run_id| runEvent(.run_started, run_id),
            .run_finished => |run_id| runEvent(.run_finished, run_id),
            .run_state_changed => |run_id| runEvent(.run_state_changed, run_id),
            .approval_requested => |run_id| runEvent(.approval_requested, run_id),
            .clipboard_write => |text| .{ .tag = .clipboard_write, .u = .{ .clipboard_write = .{ .text = sentinel(text) } } },
            .open_url => |url| .{ .tag = .open_url, .u = .{ .open_url = .{ .url = sentinel(url) } } },
            .config_changed => .{ .tag = .config_changed, .u = .{ ._reserved = zeroes() } },
            ._max => .{ .tag = ._max, .u = .{ ._reserved = zeroes() } },
        };
    }

    fn runEvent(tag: structs.ActionTag, run_id: []const u8) structs.Action {
        return .{ .tag = tag, .u = .{ .run_event = .{ .run_id = sentinel(run_id) } } };
    }

    fn sentinel(bytes: []const u8) ?[*:0]const u8 {
        if (bytes.len == 0) return "";
        return @ptrCast(bytes.ptr);
    }

    fn zeroes() [64]u8 {
        return [_]u8{0} ** 64;
    }
};

test "action tag round-trip uses C tags" {
    const a = (Action{ .open_url = "https://smithers.sh" }).cval();
    try std.testing.expectEqual(structs.ActionTag.open_url, a.tag);
    try std.testing.expectEqualStrings("https://smithers.sh", std.mem.sliceTo(a.u.open_url.url.?, 0));
}
