const std = @import("std");
const zbench = @import("zbench");
const common = @import("common.zig");
const action = @import("smithers_action");

// Measures the internal Action tagged union conversion used before invoking
// host callbacks. The current implementation exposes cvalAlloc, which replaced
// the older .cval() fast path so payload strings are safely sentinel-terminated.
// Every variant is converted, decoded back into a Zig union, and converted again.

const narrative =
    "Action tag union conversion calls cvalAlloc for every variant and decodes the C payload back into the corresponding Zig union variant.";

pub fn add(bench: *zbench.Benchmark, registry: *common.Registry) !void {
    try registry.addSimple(bench, .{
        .name = "action.cval_all_variants",
        .group = "action",
        .narrative = narrative,
        .units_per_run = 18,
        .unit = "variants",
    }, benchAllVariants, common.default_config);
}

fn benchAllVariants(allocator: std.mem.Allocator) void {
    var arena = common.freshArena(allocator);
    defer arena.deinit();

    const actions = [_]action.Action{
        .{ .none = {} },
        .{ .open_workspace = "/tmp/repo" },
        .{ .close_workspace = {} },
        .{ .new_session = .terminal },
        .{ .close_session = @ptrFromInt(0x1000) },
        .{ .focus_session = {} },
        .{ .present_command_palette = {} },
        .{ .dismiss_command_palette = {} },
        .{ .show_toast = .{ .title = "Saved", .body = "Workflow finished", .kind = 1 } },
        .{ .desktop_notify = .{ .title = "Smithers", .body = "Approval requested" } },
        .{ .run_started = "run-started" },
        .{ .run_finished = "run-finished" },
        .{ .run_state_changed = "run-state" },
        .{ .approval_requested = "approval" },
        .{ .clipboard_write = "copy text" },
        .{ .open_url = "https://smithers.sh" },
        .{ .config_changed = {} },
        .{ ._max = {} },
    };

    var checksum: usize = 0;
    inline for (actions) |act| {
        var c = act.cvalAlloc(arena.allocator()) catch @panic("action cvalAlloc failed");
        defer c.deinit();
        const back = fromC(c.action);
        var again = back.cvalAlloc(arena.allocator()) catch @panic("action cvalAlloc failed");
        defer again.deinit();
        checksum +%= score(again.action);
    }
    std.mem.doNotOptimizeAway(checksum);
}

fn fromC(c: anytype) action.Action {
    return switch (c.tag) {
        .none => .{ .none = {} },
        .open_workspace => .{ .open_workspace = spanZ(c.u.open_workspace.path) },
        .close_workspace => .{ .close_workspace = {} },
        .new_session => .{ .new_session = c.u.new_session.kind },
        .close_session => .{ .close_session = c.u.close_session.session },
        .focus_session => .{ .focus_session = {} },
        .present_command_palette => .{ .present_command_palette = {} },
        .dismiss_command_palette => .{ .dismiss_command_palette = {} },
        .show_toast => .{ .show_toast = .{
            .title = spanZ(c.u.toast.title),
            .body = spanZ(c.u.toast.body),
            .kind = c.u.toast.kind,
        } },
        .desktop_notify => .{ .desktop_notify = .{
            .title = spanZ(c.u.desktop_notify.title),
            .body = spanZ(c.u.desktop_notify.body),
        } },
        .run_started => .{ .run_started = spanZ(c.u.run_event.run_id) },
        .run_finished => .{ .run_finished = spanZ(c.u.run_event.run_id) },
        .run_state_changed => .{ .run_state_changed = spanZ(c.u.run_event.run_id) },
        .approval_requested => .{ .approval_requested = spanZ(c.u.run_event.run_id) },
        .clipboard_write => .{ .clipboard_write = spanZ(c.u.clipboard_write.text) },
        .open_url => .{ .open_url = spanZ(c.u.open_url.url) },
        .config_changed => .{ .config_changed = {} },
        ._max => .{ ._max = {} },
    };
}

fn score(c: anytype) usize {
    var total: usize = @intCast(@intFromEnum(c.tag));
    total +%= switch (c.tag) {
        .open_workspace => spanZ(c.u.open_workspace.path).len,
        .close_session => if (c.u.close_session.session) |session| @intFromPtr(session) else 0,
        .show_toast => spanZ(c.u.toast.title).len + spanZ(c.u.toast.body).len + @as(usize, @intCast(c.u.toast.kind)),
        .desktop_notify => spanZ(c.u.desktop_notify.title).len + spanZ(c.u.desktop_notify.body).len,
        .run_started, .run_finished, .run_state_changed, .approval_requested => spanZ(c.u.run_event.run_id).len,
        .clipboard_write => spanZ(c.u.clipboard_write.text).len,
        .open_url => spanZ(c.u.open_url.url).len,
        else => 0,
    };
    return total;
}

fn spanZ(ptr: ?[*:0]const u8) []const u8 {
    return if (ptr) |p| std.mem.sliceTo(p, 0) else "";
}
