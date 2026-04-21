const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage: smithers-cli palette query <QUERY> [--mode all|commands|files|workflows|workspaces|runs]
    \\
    \\Query command palette items through libsmithers and print JSON.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0 or args_pkg.isHelp(args[0])) {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    }
    if (!std.mem.eql(u8, args[0], "query")) {
        return ctx.fail("unknown palette subcommand: {s}", .{args[0]});
    }
    return query(ctx, args[1..]);
}

fn query(ctx: *Context, raw_args: []const []const u8) !void {
    var parser = args_pkg.Parser.init(raw_args);
    var mode: lib.PaletteMode = .all;
    var query_text: ?[]const u8 = null;

    while (parser.next()) |arg| {
        if (args_pkg.isHelp(arg)) {
            try ctx.stdout.writeAll(usage ++ "\n");
            return;
        }
        if (try parser.optionValue(arg, "mode")) |value| {
            mode = parseMode(value) orelse return ctx.fail("invalid palette mode: {s}", .{value});
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return args_pkg.rejectUnexpected(ctx, arg);
        if (query_text != null) return ctx.fail("palette query accepts exactly one query", .{});
        query_text = arg;
    }

    const query_value = query_text orelse return ctx.fail("palette query requires a query", .{});
    const query_z = try ctx.allocator.dupeZ(u8, query_value);
    defer ctx.allocator.free(query_z);

    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);
    const palette = try ctx.makePalette(app);
    defer lib.smithers_palette_free(palette);

    lib.smithers_palette_set_mode(palette, mode);
    lib.smithers_palette_set_query(palette, query_z.ptr);
    const items = lib.smithers_palette_items_json(palette);
    defer lib.smithers_string_free(items);
    try ctx.writeJsonRaw(lib.stringSlice(items));
}

fn parseMode(value: []const u8) ?lib.PaletteMode {
    if (std.mem.eql(u8, value, "all")) return .all;
    if (std.mem.eql(u8, value, "commands")) return .commands;
    if (std.mem.eql(u8, value, "files")) return .files;
    if (std.mem.eql(u8, value, "workflows")) return .workflows;
    if (std.mem.eql(u8, value, "workspaces")) return .workspaces;
    if (std.mem.eql(u8, value, "runs")) return .runs;
    return null;
}

test "parse palette mode" {
    try std.testing.expectEqual(lib.PaletteMode.all, parseMode("all").?);
    try std.testing.expectEqual(lib.PaletteMode.runs, parseMode("runs").?);
    try std.testing.expect(parseMode("bad") == null);
}
