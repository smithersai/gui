const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage:
    \\  smithers-cli palette query <QUERY> [--mode MODE]
    \\  smithers-cli palette activate <ITEM_ID> [--mode MODE] [--query QUERY]
    \\
    \\Options:
    \\  -m, --mode <MODE>   all|commands|files|workflows|workspaces|runs
    \\  -q, --query <TEXT>  Palette query used before activation.
    \\  -h, --help          Show help.
    \\
    \\Query command palette items through libsmithers and print JSON.
    \\
    \\Examples:
    \\  smithers-cli palette query build --mode commands
    \\  smithers-cli palette activate slash:build --query build
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
    if (std.mem.eql(u8, subcommand, "query")) return query(ctx, parser.remaining());
    if (std.mem.eql(u8, subcommand, "activate")) return activate(ctx, parser.remaining());
    return ctx.fail("unknown palette subcommand: {s}", .{subcommand});
}

const PaletteOptions = struct {
    mode: lib.PaletteMode = .all,
    query_text: ?[]const u8 = null,
    item_id: ?[]const u8 = null,
};

fn parsePaletteOptions(ctx: *Context, raw_args: []const []const u8, need_item_id: bool) !PaletteOptions {
    var parser = args_pkg.Parser.init(raw_args);
    var options = PaletteOptions{};

    while (parser.next()) |arg| {
        if (try parser.optionValueAny(arg, "mode", 'm')) |value| {
            options.mode = parseMode(value) orelse {
                try ctx.fail("invalid palette mode: {s}", .{value});
                unreachable;
            };
            continue;
        }
        if (try parser.optionValueAny(arg, "query", 'q')) |value| {
            options.query_text = value;
            continue;
        }
        if (args_pkg.isGlobalFlag(arg)) continue;
        if (std.mem.startsWith(u8, arg, "-")) {
            try args_pkg.rejectUnexpected(ctx, arg);
            unreachable;
        }

        if (need_item_id) {
            if (options.item_id != null) {
                try ctx.fail("palette activate accepts exactly one item id", .{});
                unreachable;
            }
            options.item_id = arg;
        } else {
            if (options.query_text != null) {
                try ctx.fail("palette query accepts exactly one query", .{});
                unreachable;
            }
            options.query_text = arg;
        }
    }

    return options;
}

fn query(ctx: *Context, raw_args: []const []const u8) !void {
    const options = try parsePaletteOptions(ctx, raw_args, false);
    const query_value = options.query_text orelse return ctx.fail("palette query requires a query", .{});
    const query_z = try ctx.allocator.dupeZ(u8, query_value);
    defer ctx.allocator.free(query_z);

    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);
    const palette = try ctx.makePalette(app);
    defer lib.smithers_palette_free(palette);

    lib.smithers_palette_set_mode(palette, options.mode);
    lib.smithers_palette_set_query(palette, query_z.ptr);
    const items = lib.smithers_palette_items_json(palette);
    defer lib.smithers_string_free(items);
    try ctx.writeJsonRaw(lib.stringSlice(items));
}

fn activate(ctx: *Context, raw_args: []const []const u8) !void {
    const options = try parsePaletteOptions(ctx, raw_args, true);
    const item_id = options.item_id orelse return ctx.fail("palette activate requires an item id", .{});
    const item_id_z = try ctx.allocator.dupeZ(u8, item_id);
    defer ctx.allocator.free(item_id_z);
    const query_z = if (options.query_text) |value| try ctx.allocator.dupeZ(u8, value) else null;
    defer if (query_z) |value| ctx.allocator.free(value);

    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);
    const palette = try ctx.makePalette(app);
    defer lib.smithers_palette_free(palette);

    lib.smithers_palette_set_mode(palette, options.mode);
    if (query_z) |value| lib.smithers_palette_set_query(palette, value.ptr);

    const err = lib.smithers_palette_activate(palette, item_id_z.ptr);
    defer lib.smithers_error_free(err);
    if (err.code != 0) {
        const message = lib.errorMessage(err);
        return ctx.fail("palette activate failed: {s}", .{if (message.len == 0) "unknown error" else message});
    }

    if (ctx.globals.json) {
        try ctx.writeJson(.{ .ok = true, .itemId = item_id });
    } else {
        try ctx.stdout.writeAll("ok\n");
    }
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
