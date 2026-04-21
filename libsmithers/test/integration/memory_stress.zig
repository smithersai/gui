const std = @import("std");
const lib = @import("libsmithers");
const h = @import("helpers.zig");

const App = lib.App;
const Palette = lib.commands.palette.Palette;
const Session = lib.session;

test "10k session palette text loop returns to steady memory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makeDir("workspace");
    const workspace_path = try h.tempPath(&tmp, "workspace");
    defer std.testing.allocator.free(workspace_path);

    var app = try App.create(std.testing.allocator, .{});
    defer app.destroy();
    _ = try app.openWorkspace(workspace_path);

    for (0..10_000) |_| {
        const session = try Session.create(app, .{ .kind = .chat });
        var palette = try Palette.create(app);

        palette.setMode(.commands);
        palette.setQuery("terminal");
        const items = palette.itemsJson();
        h.ffi.stringFree(items);

        session.sendText("hello integration");
        const stream = session.events();
        const ev = stream.next();
        h.ffi.stringFree(ev.payload);
        try std.testing.expectEqual(h.structs.EventTag.json, ev.tag);
        stream.destroy();

        palette.destroy();
        session.destroy();
    }

    try std.testing.expectEqual(@as(usize, 0), app.sessions.items.len);
}
