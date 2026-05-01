const Session = @This();

const std = @import("std");
const smithers = @import("smithers.zig");
const Application = @import("class/application.zig").Application;
const SessionWidget = @import("class/session.zig").SessionWidget;

widget: *SessionWidget,

pub fn new(
    app: *Application,
    kind: smithers.c.smithers_session_kind_e,
    workspace_path: ?[]const u8,
    target_id: ?[]const u8,
) !Session {
    return .{
        .widget = try SessionWidget.new(app, kind, workspace_path, target_id),
    };
}

pub fn deinit(self: *Session) void {
    self.widget.unref();
}

pub fn gobj(self: *Session) *SessionWidget {
    return self.widget;
}

pub fn title(self: *Session, alloc: std.mem.Allocator) ![]u8 {
    return self.widget.title(alloc);
}
