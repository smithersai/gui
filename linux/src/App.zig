const App = @This();

const std = @import("std");
const Application = @import("class/application.zig").Application;

app: *Application,

pub const Options = struct {
    smoke: bool = false,
    show_palette: bool = false,
};

pub fn init(alloc: std.mem.Allocator, opts: Options) !App {
    const app = try Application.new(alloc, opts);
    errdefer app.unref();
    return .{ .app = app };
}

pub fn deinit(self: *App) void {
    self.app.deinit();
    self.app.unref();
}

pub fn run(self: *App) !void {
    try self.app.run();
}

pub fn wakeup(self: *App) void {
    self.app.wakeup();
}

pub fn presentCommandPalette(self: *App) void {
    self.app.presentCommandPalette();
}
