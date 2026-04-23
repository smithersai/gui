const std = @import("std");
const App = @import("App.zig");
const class = @import("class.zig");
const logx = @import("log.zig");

const log = std.log.scoped(.smithers_gtk_main);

/// Install our custom logging backend (timestamps + scope + level) and set
/// the default log level. Overridable at runtime by `SMITHERS_LOG_LEVEL`.
pub const std_options: std.Options = .{
    .log_level = logx.default_level,
    .logFn = logx.logFn,
};

pub fn main() !void {
    logx.initProcessClock();

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

    log.info("smithers-gtk starting smoke={} show_palette={} argc={d}", .{
        opts.smoke, opts.show_palette, args.len,
    });

    var app = App.init(alloc, opts) catch |err| {
        log.err("App.init failed: {s}", .{@errorName(err)});
        return err;
    };
    defer app.deinit();
    app.run() catch |err| {
        log.err("App.run exited with error: {s}", .{@errorName(err)});
        return err;
    };

    log.info("smithers-gtk exited cleanly", .{});
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(class);
}
