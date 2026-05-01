const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage: smithers-cli cwd resolve [PATH]
    \\
    \\Options:
    \\  -h, --help   Show help.
    \\
    \\Resolve a requested working directory through libsmithers.
    \\
    \\Examples:
    \\  smithers-cli cwd resolve
    \\  smithers-cli cwd resolve /tmp/project
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
    if (!std.mem.eql(u8, subcommand, "resolve")) {
        return ctx.fail("unknown cwd subcommand: {s}", .{subcommand});
    }

    var requested: ?[]const u8 = null;
    while (parser.nextNonGlobal()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) return args_pkg.rejectUnexpected(ctx, arg);
        if (requested != null) return ctx.fail("cwd resolve accepts at most one path", .{});
        requested = arg;
    }

    const requested_z = if (requested) |value| try ctx.allocator.dupeZ(u8, value) else null;
    defer if (requested_z) |value| ctx.allocator.free(value);

    const resolved = lib.smithers_cwd_resolve(if (requested_z) |value| value.ptr else null);
    defer lib.smithers_string_free(resolved);
    const path = lib.stringSlice(resolved);

    if (ctx.globals.json) {
        try ctx.writeJson(.{ .path = path });
    } else {
        try ctx.stdout.print("{s}\n", .{path});
    }
}
