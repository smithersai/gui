const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage: smithers-cli event drain
    \\
    \\Options:
    \\  -h, --help   Show help.
    \\
    \\Internal dev command: initialize an app with default callbacks and drain one tick.
    \\
    \\Examples:
    \\  smithers-cli event drain --verbose
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args_pkg.containsHelp(args)) {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    }

    var parser = args_pkg.Parser.init(args);
    const subcommand = parser.nextNonGlobal() orelse {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    };
    if (!std.mem.eql(u8, subcommand, "drain")) {
        return ctx.fail("unknown event subcommand: {s}", .{subcommand});
    }
    while (parser.nextNonGlobal()) |arg| {
        return args_pkg.rejectUnexpected(ctx, arg);
    }

    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);
    lib.smithers_app_tick(app);

    if (ctx.globals.json) {
        try ctx.writeJsonRaw("{\"events\":[]}");
    } else if (ctx.globals.verbose) {
        try ctx.stdout.writeAll("no events\n");
    }
}
