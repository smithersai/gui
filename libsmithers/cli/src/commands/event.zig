const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage: smithers-cli event drain
    \\
    \\Internal dev command: initialize an app with default callbacks and drain one tick.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0 or args_pkg.isHelp(args[0])) {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    }

    if (!std.mem.eql(u8, args[0], "drain")) {
        return ctx.fail("unknown event subcommand: {s}", .{args[0]});
    }
    if (args.len != 1) return ctx.fail("event drain does not accept arguments", .{});

    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);
    lib.smithers_app_tick(app);

    if (ctx.globals.json) {
        try ctx.writeJsonRaw("{\"events\":[]}");
    } else if (ctx.globals.verbose) {
        try ctx.stdout.writeAll("no events\n");
    }
}
