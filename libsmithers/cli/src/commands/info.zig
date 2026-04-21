const std = @import("std");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage: smithers-cli info
    \\
    \\Print libsmithers version, commit, and platform.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len != 0) return ctx.fail("info does not accept arguments", .{});

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
