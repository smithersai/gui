const std = @import("std");
const App = @import("App.zig");
const class = @import("class.zig");

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const alloc = debug_allocator.allocator();

    var args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    var opts = App.Options{};
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) opts.smoke = true;
        if (std.mem.eql(u8, arg, "--show-palette")) opts.show_palette = true;
    }

    var app = try App.init(alloc, opts);
    defer app.deinit();
    try app.run();
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(class);
}
