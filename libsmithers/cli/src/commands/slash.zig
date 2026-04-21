const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage: smithers-cli slash parse <INPUT>
    \\
    \\Parse a slash-command input through libsmithers and print JSON.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0 or args_pkg.isHelp(args[0])) {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    }
    if (!std.mem.eql(u8, args[0], "parse")) {
        return ctx.fail("unknown slash subcommand: {s}", .{args[0]});
    }
    if (args.len != 2) return ctx.fail("slash parse requires exactly one input", .{});

    const input_z = try ctx.allocator.dupeZ(u8, args[1]);
    defer ctx.allocator.free(input_z);

    const parsed = lib.smithers_slashcmd_parse(input_z.ptr);
    defer lib.smithers_string_free(parsed);
    try ctx.writeJsonRaw(lib.stringSlice(parsed));
}
