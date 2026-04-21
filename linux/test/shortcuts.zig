const std = @import("std");

const shortcuts = @import("shortcuts");

test "default accelerators cover all actions" {
    try std.testing.expectEqual(@as(usize, shortcuts.Action.len), shortcuts.actions.len);
    try std.testing.expectEqual(@as(usize, shortcuts.Action.len), shortcuts.default_accel.len);
    for (shortcuts.actions) |action| {
        try std.testing.expect(shortcuts.default_accel[action.index()].len > 0);
        try std.testing.expect(shortcuts.fromName(action.storageKey()) == action);
        try std.testing.expect(shortcuts.fromName(action.actionName()) == action);
        try std.testing.expect(shortcuts.fromName(@tagName(action)) == action);
    }
}

test "default accelerator format parses under GTK" {
    const alloc = std.testing.allocator;
    for (shortcuts.actions) |action| {
        const accel = shortcuts.default_accel[action.index()];
        const accel_z = try alloc.dupeZ(u8, accel);
        defer alloc.free(accel_z);

        try std.testing.expect(shortcuts.gtkAcceleratorParses(accel_z));
    }
}

test "load and save shortcut overrides round trip" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer alloc.free(tmp_path);
    const path = try std.fs.path.join(alloc, &.{ tmp_path, "shortcuts.json" });
    defer alloc.free(path);

    var bindings = shortcuts.Bindings{ .allocator = alloc };
    defer bindings.deinit();
    try bindings.setOverride(alloc, .new_tab, .{ .key = "x", .command = true, .shift = true });
    try bindings.setOverride(alloc, .toggle_sidebar, .{ .key = "b", .command = true, .option = true });
    try shortcuts.save(alloc, path, bindings);

    var loaded = try shortcuts.load(alloc, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("<Primary><Shift>x", loaded.accel(.new_tab));
    try std.testing.expectEqualStrings("<Primary><Alt>b", loaded.accel(.toggle_sidebar));
}

test "overriding one action does not affect defaults for others" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try std.fs.path.join(alloc, &.{ ".zig-cache", "tmp", tmp.sub_path[0..] });
    defer alloc.free(tmp_path);
    const path = try std.fs.path.join(alloc, &.{ tmp_path, "shortcuts.json" });
    defer alloc.free(path);

    var bindings = shortcuts.Bindings{ .allocator = alloc };
    defer bindings.deinit();
    try bindings.setOverride(alloc, .new_tab, .{ .key = "y", .command = true });
    try shortcuts.save(alloc, path, bindings);

    var loaded = try shortcuts.load(alloc, path);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("<Primary>y", loaded.accel(.new_tab));
    try std.testing.expectEqualStrings(shortcuts.default_accel[shortcuts.Action.close_tab.index()], loaded.accel(.close_tab));
}
