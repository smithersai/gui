const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage:
    \\  smithers-cli workspace list
    \\  smithers-cli workspace open <PATH>
    \\
    \\List recent workspaces or open a workspace through libsmithers.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0 or args_pkg.isHelp(args[0])) {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    }

    const subcommand = args[0];
    if (std.mem.eql(u8, subcommand, "list")) return list(ctx, args[1..]);
    if (std.mem.eql(u8, subcommand, "open")) return open(ctx, args[1..]);
    return ctx.fail("unknown workspace subcommand: {s}", .{subcommand});
}

fn list(ctx: *Context, args: []const []const u8) !void {
    if (args.len != 0) return ctx.fail("workspace list does not accept arguments", .{});
    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);

    const json = lib.smithers_app_recent_workspaces_json(app);
    defer lib.smithers_string_free(json);
    try ctx.writeJsonRaw(lib.stringSlice(json));
}

fn open(ctx: *Context, args: []const []const u8) !void {
    if (args.len != 1) return ctx.fail("workspace open requires exactly one path", .{});
    const path_z = try ctx.allocator.dupeZ(u8, args[0]);
    defer ctx.allocator.free(path_z);

    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);

    const workspace = lib.smithers_app_open_workspace(app, path_z.ptr);
    if (workspace == null) return ctx.fail("failed to open workspace: {s}", .{args[0]});

    const active = lib.smithers_app_active_workspace_path(app);
    defer lib.smithers_string_free(active);
    const path = lib.stringSlice(active);

    if (ctx.globals.json) {
        try ctx.writeJson(.{ .path = path });
    } else {
        try ctx.stdout.print("{s}\n", .{path});
    }
}
