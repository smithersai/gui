const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage:
    \\  smithers-cli workspace list
    \\  smithers-cli workspace open <PATH>
    \\
    \\Options:
    \\  -h, --help   Show help.
    \\
    \\List recent workspaces or open a workspace through libsmithers.
    \\
    \\Examples:
    \\  smithers-cli workspace list
    \\  smithers-cli workspace open .
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
    if (std.mem.eql(u8, subcommand, "list")) return list(ctx, parser.remaining());
    if (std.mem.eql(u8, subcommand, "open")) return open(ctx, parser.remaining());
    return ctx.fail("unknown workspace subcommand: {s}", .{subcommand});
}

fn list(ctx: *Context, args: []const []const u8) !void {
    for (args) |arg| {
        if (args_pkg.isGlobalFlag(arg)) continue;
        return ctx.fail("workspace list does not accept arguments", .{});
    }
    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);

    const json = lib.smithers_app_recent_workspaces_json(app);
    defer lib.smithers_string_free(json);
    try ctx.writeJsonRaw(lib.stringSlice(json));
}

fn open(ctx: *Context, args: []const []const u8) !void {
    var parser = args_pkg.Parser.init(args);
    var path: ?[]const u8 = null;
    while (parser.nextNonGlobal()) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) return args_pkg.rejectUnexpected(ctx, arg);
        if (path != null) return ctx.fail("workspace open requires exactly one path", .{});
        path = arg;
    }

    const path_value = path orelse return ctx.fail("workspace open requires exactly one path", .{});
    const path_z = try ctx.allocator.dupeZ(u8, path_value);
    defer ctx.allocator.free(path_z);

    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);

    const workspace = lib.smithers_app_open_workspace(app, path_z.ptr);
    if (workspace == null) return ctx.fail("failed to open workspace: {s}", .{path_value});

    const active = lib.smithers_app_active_workspace_path(app);
    defer lib.smithers_string_free(active);
    const active_path = lib.stringSlice(active);

    if (ctx.globals.json) {
        try ctx.writeJson(.{ .path = active_path });
    } else {
        try ctx.stdout.print("{s}\n", .{active_path});
    }
}
