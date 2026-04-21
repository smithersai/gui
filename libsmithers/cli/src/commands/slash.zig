const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage: smithers-cli slash parse <INPUT>
    \\
    \\Options:
    \\  -h, --help   Show help.
    \\
    \\Parse a slash-command input through libsmithers and print JSON.
    \\
    \\Examples:
    \\  smithers-cli slash parse "/build foo"
    \\  smithers-cli --json slash parse "/help"
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
    if (!std.mem.eql(u8, subcommand, "parse")) {
        return ctx.fail("unknown slash subcommand: {s}", .{subcommand});
    }

    var input: ?[]const u8 = null;
    while (parser.nextNonGlobal()) |arg| {
        if (input != null) return ctx.fail("slash parse requires exactly one input", .{});
        input = arg;
    }
    const input_value = input orelse return ctx.fail("slash parse requires exactly one input", .{});

    const input_z = try ctx.allocator.dupeZ(u8, input_value);
    defer ctx.allocator.free(input_z);

    const parsed = lib.smithers_slashcmd_parse(input_z.ptr);
    defer lib.smithers_string_free(parsed);
    try ctx.writeJsonRaw(lib.stringSlice(parsed));
}
