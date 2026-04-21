const std = @import("std");

pub const c = @cImport({
    @cInclude("smithers.h");
});

pub const Error = error{
    SmithersCallFailed,
    NullString,
};

pub fn ownedString(alloc: std.mem.Allocator, s: c.smithers_string_s) ![]u8 {
    defer c.smithers_string_free(s);
    if (s.ptr == null or s.len == 0) return alloc.dupe(u8, "");
    return try alloc.dupe(u8, @as([*]const u8, @ptrCast(s.ptr))[0..s.len]);
}

pub fn callJson(
    alloc: std.mem.Allocator,
    client: c.smithers_client_t,
    method: []const u8,
    args_json: []const u8,
) ![]u8 {
    const method_z = try alloc.dupeZ(u8, method);
    defer alloc.free(method_z);
    const args_z = try alloc.dupeZ(u8, args_json);
    defer alloc.free(args_z);

    var err = std.mem.zeroes(c.smithers_error_s);
    const result = c.smithers_client_call(client, method_z.ptr, args_z.ptr, &err);
    defer c.smithers_error_free(err);

    if (err.code != 0) return Error.SmithersCallFailed;
    return try ownedString(alloc, result);
}

pub fn paletteItemsJson(alloc: std.mem.Allocator, palette: c.smithers_palette_t) ![]u8 {
    return try ownedString(alloc, c.smithers_palette_items_json(palette));
}

pub fn activeWorkspacePath(alloc: std.mem.Allocator, app: c.smithers_app_t) ![]u8 {
    return try ownedString(alloc, c.smithers_app_active_workspace_path(app));
}

pub fn recentWorkspacesJson(alloc: std.mem.Allocator, app: c.smithers_app_t) ![]u8 {
    return try ownedString(alloc, c.smithers_app_recent_workspaces_json(app));
}

pub fn sessionTitle(alloc: std.mem.Allocator, session: c.smithers_session_t) ![]u8 {
    return try ownedString(alloc, c.smithers_session_title(session));
}

pub fn cwdResolve(alloc: std.mem.Allocator, requested: ?[]const u8) ![]u8 {
    if (requested) |value| {
        const z = try alloc.dupeZ(u8, value);
        defer alloc.free(z);
        return try ownedString(alloc, c.smithers_cwd_resolve(z.ptr));
    }
    return try ownedString(alloc, c.smithers_cwd_resolve(null));
}

pub fn actionName(tag: c.smithers_action_tag_e) []const u8 {
    return switch (tag) {
        c.SMITHERS_ACTION_NONE => "none",
        c.SMITHERS_ACTION_OPEN_WORKSPACE => "open-workspace",
        c.SMITHERS_ACTION_CLOSE_WORKSPACE => "close-workspace",
        c.SMITHERS_ACTION_NEW_SESSION => "new-session",
        c.SMITHERS_ACTION_CLOSE_SESSION => "close-session",
        c.SMITHERS_ACTION_FOCUS_SESSION => "focus-session",
        c.SMITHERS_ACTION_PRESENT_COMMAND_PALETTE => "present-command-palette",
        c.SMITHERS_ACTION_DISMISS_COMMAND_PALETTE => "dismiss-command-palette",
        c.SMITHERS_ACTION_SHOW_TOAST => "show-toast",
        c.SMITHERS_ACTION_DESKTOP_NOTIFY => "desktop-notify",
        c.SMITHERS_ACTION_RUN_STARTED => "run-started",
        c.SMITHERS_ACTION_RUN_FINISHED => "run-finished",
        c.SMITHERS_ACTION_RUN_STATE_CHANGED => "run-state-changed",
        c.SMITHERS_ACTION_APPROVAL_REQUESTED => "approval-requested",
        c.SMITHERS_ACTION_CLIPBOARD_WRITE => "clipboard-write",
        c.SMITHERS_ACTION_OPEN_URL => "open-url",
        c.SMITHERS_ACTION_CONFIG_CHANGED => "config-changed",
        else => "unknown",
    };
}
