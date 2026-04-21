const std = @import("std");
const structs = @import("structs.zig");
const Allocator = std.mem.Allocator;

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

    pub const CValue = struct {
        allocator: Allocator,
        action: structs.Action,
        owned: [4]?[:0]u8 = .{null} ** 4,
        owned_len: usize = 0,

        pub fn deinit(self: *CValue) void {
            for (self.owned[0..self.owned_len]) |maybe_owned| {
                if (maybe_owned) |owned| self.allocator.free(owned);
            }
            self.owned_len = 0;
        }

        fn z(self: *CValue, bytes: []const u8) Allocator.Error!?[*:0]const u8 {
            if (bytes.len == 0) return "";
            std.debug.assert(self.owned_len < self.owned.len);
            const owned = try self.allocator.dupeZ(u8, bytes);
            self.owned[self.owned_len] = owned;
            self.owned_len += 1;
            return owned.ptr;
        }
    };

    pub fn cvalAlloc(self: Action, allocator: Allocator) Allocator.Error!CValue {
        var result = CValue{
            .allocator = allocator,
            .action = .{ .tag = .none, .u = .{ ._reserved = zeroes() } },
        };
        errdefer result.deinit();

        result.action = switch (self) {
            .none => .{ .tag = .none, .u = .{ ._reserved = zeroes() } },
            .open_workspace => |path| .{ .tag = .open_workspace, .u = .{ .open_workspace = .{ .path = try result.z(path) } } },
            .close_workspace => .{ .tag = .close_workspace, .u = .{ ._reserved = zeroes() } },
            .new_session => .{ .tag = .new_session, .u = .{ ._reserved = zeroes() } },
            .close_session => |session| .{ .tag = .close_session, .u = .{ .close_session = .{ .session = session } } },
            .focus_session => .{ .tag = .focus_session, .u = .{ ._reserved = zeroes() } },
            .present_command_palette => .{ .tag = .present_command_palette, .u = .{ ._reserved = zeroes() } },
            .dismiss_command_palette => .{ .tag = .dismiss_command_palette, .u = .{ ._reserved = zeroes() } },
            .show_toast => |toast| .{ .tag = .show_toast, .u = .{ .toast = .{
                .title = try result.z(toast.title),
                .body = try result.z(toast.body),
                .kind = toast.kind,
            } } },
            .desktop_notify => |n| .{ .tag = .desktop_notify, .u = .{ .desktop_notify = .{
                .title = try result.z(n.title),
                .body = try result.z(n.body),
            } } },
            .run_started => |run_id| try runEvent(&result, .run_started, run_id),
            .run_finished => |run_id| try runEvent(&result, .run_finished, run_id),
            .run_state_changed => |run_id| try runEvent(&result, .run_state_changed, run_id),
            .approval_requested => |run_id| try runEvent(&result, .approval_requested, run_id),
            .clipboard_write => |text| .{ .tag = .clipboard_write, .u = .{ .clipboard_write = .{ .text = try result.z(text) } } },
            .open_url => |url| .{ .tag = .open_url, .u = .{ .open_url = .{ .url = try result.z(url) } } },
            .config_changed => .{ .tag = .config_changed, .u = .{ ._reserved = zeroes() } },
            ._max => .{ .tag = ._max, .u = .{ ._reserved = zeroes() } },
        };
        return result;
    }

    fn runEvent(result: *CValue, tag: structs.ActionTag, run_id: []const u8) Allocator.Error!structs.Action {
        return .{ .tag = tag, .u = .{ .run_event = .{ .run_id = try result.z(run_id) } } };
    }

    fn zeroes() [64]u8 {
        return [_]u8{0} ** 64;
    }
};

test "action tag round-trip uses C tags" {
    var c = try (Action{ .open_url = "https://smithers.sh" }).cvalAlloc(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(structs.ActionTag.open_url, c.action.tag);
    try std.testing.expectEqualStrings("https://smithers.sh", std.mem.sliceTo(c.action.u.open_url.url.?, 0));
}
