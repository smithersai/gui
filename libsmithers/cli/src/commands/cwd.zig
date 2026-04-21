const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage: smithers-cli cwd resolve [PATH]
    \\
    \\Resolve a requested working directory through libsmithers.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0 or args_pkg.isHelp(args[0])) {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    }

    const subcommand = args[0];
    if (!std.mem.eql(u8, subcommand, "resolve")) {
        return ctx.fail("unknown cwd subcommand: {s}", .{subcommand});
    }

    if (args.len > 2) return ctx.fail("cwd resolve accepts at most one path", .{});
    const requested_z = if (args.len == 2)
        try ctx.allocator.dupeZ(u8, args[1])
    else
        null;
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

const std = @import("std");
