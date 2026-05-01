const std = @import("std");
const lib = @import("libsmithers");
const fuzz_corpus = @import("fuzz_corpus");

const action = lib.apprt.action;
const structs = lib.apprt.structs;

const max_payload = 16 * 1024;

test "fuzz action tag roundtrip" {
    try std.testing.fuzz({}, fuzzOne, .{ .corpus = fuzz_corpus.corpus });
}

fn fuzzOne(_: void, input: []const u8) !void {
    const payload = if (input.len > 1)
        input[1..@min(input.len, max_payload + 1)]
    else
        "";
    const selector = if (input.len == 0) 0 else input[0] % 12;

    switch (selector) {
        0 => try expectTag(.none, action.Action.none),
        1 => try expectStringAction(.open_workspace, action.Action{ .open_workspace = payload }, payload),
        2 => try expectTag(.close_workspace, action.Action.close_workspace),
        3 => try expectTag(.new_session, action.Action{ .new_session = .terminal }),
        4 => try expectTag(.focus_session, action.Action.focus_session),
        5 => try expectTag(.present_command_palette, action.Action.present_command_palette),
        6 => try expectToast(payload),
        7 => try expectDesktopNotification(payload),
        8 => try expectStringAction(.run_started, action.Action{ .run_started = payload }, payload),
        9 => try expectStringAction(.clipboard_write, action.Action{ .clipboard_write = payload }, payload),
        10 => try expectStringAction(.open_url, action.Action{ .open_url = payload }, payload),
        else => try expectTag(.config_changed, action.Action.config_changed),
    }
}

fn expectTag(expected_tag: structs.ActionTag, act: action.Action) !void {
    var c = try act.cvalAlloc(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(expected_tag, c.action.tag);
}

fn expectStringAction(expected_tag: structs.ActionTag, act: action.Action, expected_payload: []const u8) !void {
    var c = try act.cvalAlloc(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(expected_tag, c.action.tag);
    const ptr = switch (expected_tag) {
        .open_workspace => c.action.u.open_workspace.path,
        .run_started, .run_finished, .run_state_changed, .approval_requested => c.action.u.run_event.run_id,
        .clipboard_write => c.action.u.clipboard_write.text,
        .open_url => c.action.u.open_url.url,
        else => null,
    };
    try expectCString(ptr, expected_payload);
}

fn expectToast(payload: []const u8) !void {
    const split = payload.len / 2;
    var c = try (action.Action{ .show_toast = .{
        .title = payload[0..split],
        .body = payload[split..],
        .kind = @intCast(payload.len % 7),
    } }).cvalAlloc(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(structs.ActionTag.show_toast, c.action.tag);
    try expectCString(c.action.u.toast.title, payload[0..split]);
    try expectCString(c.action.u.toast.body, payload[split..]);
}

fn expectDesktopNotification(payload: []const u8) !void {
    const split = payload.len / 2;
    var c = try (action.Action{ .desktop_notify = .{
        .title = payload[0..split],
        .body = payload[split..],
    } }).cvalAlloc(std.testing.allocator);
    defer c.deinit();
    try std.testing.expectEqual(structs.ActionTag.desktop_notify, c.action.tag);
    try expectCString(c.action.u.desktop_notify.title, payload[0..split]);
    try expectCString(c.action.u.desktop_notify.body, payload[split..]);
}

fn expectCString(ptr: ?[*:0]const u8, expected: []const u8) !void {
    const actual = if (ptr) |p| std.mem.sliceTo(p, 0) else "";
    try std.testing.expectEqualSlices(u8, cStringPrefix(expected), actual);
}

fn cStringPrefix(input: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, input, 0)) |idx| return input[0..idx];
    return input;
}
