const std = @import("std");
const h = @import("helpers.zig");

var palette_state: ?*PaletteState = null;

const PaletteState = struct {
    new_session_actions: usize = 0,
    dismiss_actions: usize = 0,
    last_tag: h.structs.ActionTag = .none,

    fn action(app_ptr: ?*anyopaque, target: h.structs.ActionTarget, act: h.structs.Action) callconv(.c) bool {
        _ = app_ptr;
        const state = palette_state.?;
        state.last_tag = act.tag;
        switch (act.tag) {
            .new_session => {
                state.new_session_actions += 1;
                std.testing.expectEqual(h.structs.ActionTargetTag.app, target.tag) catch unreachable;
            },
            .dismiss_command_palette => {
                state.dismiss_actions += 1;
                std.testing.expectEqual(h.structs.ActionTargetTag.app, target.tag) catch unreachable;
            },
            else => {},
        }
        return true;
    }
};

test "palette mode query items shape and activation callback" {
    var state = PaletteState{};
    palette_state = &state;
    defer palette_state = null;

    const cfg = h.structs.RuntimeConfig{ .action = PaletteState.action };
    const app = h.embedded.smithers_app_new(&cfg).?;
    defer h.embedded.smithers_app_free(app);

    const palette = h.embedded.smithers_palette_new(app).?;
    defer h.embedded.smithers_palette_free(palette);
    h.embedded.smithers_palette_set_mode(palette, .commands);
    h.embedded.smithers_palette_set_query(palette, "terminal");

    const items = h.embedded.smithers_palette_items_json(palette);
    defer h.embedded.smithers_string_free(items);
    var parsed = try h.expectJsonArray(h.stringSlice(items));
    defer parsed.deinit();
    try std.testing.expect(parsed.value.array.items.len > 0);

    var found_terminal = false;
    for (parsed.value.array.items) |item| {
        const object = item.object;
        try std.testing.expect(object.get("id") != null);
        try std.testing.expect(object.get("title") != null);
        try std.testing.expect(object.get("subtitle") != null);
        try std.testing.expect(object.get("kind") != null);
        try std.testing.expect(object.get("score") != null);
        if (std.mem.eql(u8, object.get("id").?.string, "command.new-terminal")) {
            found_terminal = true;
            try std.testing.expectEqualStrings("New Terminal Workspace", object.get("title").?.string);
            try std.testing.expectEqualStrings("command", object.get("kind").?.string);
        }
    }
    try std.testing.expect(found_terminal);

    const activation = h.embedded.smithers_palette_activate(palette, "command.new-terminal");
    defer h.embedded.smithers_error_free(activation);
    try h.expectSuccess(activation);
    try std.testing.expectEqual(@as(usize, 1), state.new_session_actions);
    try std.testing.expectEqual(h.structs.ActionTag.new_session, state.last_tag);
}

test "palette activation reports missing items and dispatches dismiss command" {
    var state = PaletteState{};
    palette_state = &state;
    defer palette_state = null;

    const cfg = h.structs.RuntimeConfig{ .action = PaletteState.action };
    const app = h.embedded.smithers_app_new(&cfg).?;
    defer h.embedded.smithers_app_free(app);
    const palette = h.embedded.smithers_palette_new(app).?;
    defer h.embedded.smithers_palette_free(palette);

    const dismiss = h.embedded.smithers_palette_activate(palette, "command.palette.dismiss");
    defer h.embedded.smithers_error_free(dismiss);
    try h.expectSuccess(dismiss);
    try std.testing.expectEqual(@as(usize, 1), state.dismiss_actions);

    const missing = h.embedded.smithers_palette_activate(palette, "command.does-not-exist");
    defer h.embedded.smithers_error_free(missing);
    try h.expectError(missing, 404, "not found");
}
