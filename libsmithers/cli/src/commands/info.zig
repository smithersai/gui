const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage: smithers-cli info
    \\
    \\Options:
    \\  -h, --help   Show help.
    \\
    \\Print libsmithers version, commit, and platform.
    \\
    \\Examples:
    \\  smithers-cli info
    \\  smithers-cli info --json
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args_pkg.containsHelp(args)) {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    }
    for (args) |arg| {
        if (args_pkg.isGlobalFlag(arg)) continue;
        return ctx.fail("info does not accept arguments", .{});
    }

    const info = lib.smithers_info();
    if (ctx.globals.json) {
        try ctx.writeJson(.{
            .version = std.mem.sliceTo(info.version, 0),
            .commit = std.mem.sliceTo(info.commit, 0),
            .platform = lib.platformName(info.platform),
        });
        return;
    }

    try ctx.stdout.print("version: {s}\n", .{std.mem.sliceTo(info.version, 0)});
    try ctx.stdout.print("commit: {s}\n", .{std.mem.sliceTo(info.commit, 0)});
    try ctx.stdout.print("platform: {s}\n", .{lib.platformName(info.platform)});
}
