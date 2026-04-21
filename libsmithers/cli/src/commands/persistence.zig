const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage:
    \\  smithers-cli persistence load --db <PATH> --workspace <PATH>
    \\  smithers-cli persistence save --db <PATH> --workspace <PATH> --input -
    \\
    \\Load or save persisted session JSON through libsmithers.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0 or args_pkg.isHelp(args[0])) {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    }

    const subcommand = args[0];
    if (std.mem.eql(u8, subcommand, "load")) return load(ctx, args[1..]);
    if (std.mem.eql(u8, subcommand, "save")) return save(ctx, args[1..]);
    return ctx.fail("unknown persistence subcommand: {s}", .{subcommand});
}

const Options = struct {
    db: ?[]const u8 = null,
    workspace: ?[]const u8 = null,
    input: ?[]const u8 = null,
};

fn parseOptions(ctx: *Context, raw_args: []const []const u8, allow_input: bool) !Options {
    var parser = args_pkg.Parser.init(raw_args);
    var options = Options{};

    while (parser.next()) |arg| {
        if (args_pkg.isHelp(arg)) {
            try ctx.stdout.writeAll(usage ++ "\n");
            return error.CliFailure;
        }
        if (try parser.optionValue(arg, "db")) |value| {
            options.db = value;
            continue;
        }
        if (try parser.optionValue(arg, "workspace")) |value| {
            options.workspace = value;
            continue;
        }
        if (allow_input) {
            if (try parser.optionValue(arg, "input")) |value| {
                options.input = value;
                continue;
            }
        }
        try args_pkg.rejectUnexpected(ctx, arg);
        unreachable;
    }

    return options;
}

fn openStore(ctx: *Context, db_path: []const u8) !lib.Persistence {
    const db_z = try ctx.allocator.dupeZ(u8, db_path);
    defer ctx.allocator.free(db_z);

    var err: lib.Error = .{ .code = 0, .msg = null };
    const persistence = lib.smithers_persistence_open(db_z.ptr, &err);
    defer lib.smithers_error_free(err);
    if (err.code != 0) {
        const message = lib.errorMessage(err);
        try ctx.fail("persistence open failed: {s}", .{if (message.len == 0) "unknown error" else message});
        unreachable;
    }
    if (persistence == null) {
        try ctx.fail("persistence open returned no handle", .{});
        unreachable;
    }
    return persistence;
}

fn load(ctx: *Context, raw_args: []const []const u8) !void {
    const options = try parseOptions(ctx, raw_args, false);
    const db = options.db orelse return ctx.fail("persistence load requires --db", .{});
    const workspace = options.workspace orelse return ctx.fail("persistence load requires --workspace", .{});
    const workspace_z = try ctx.allocator.dupeZ(u8, workspace);
    defer ctx.allocator.free(workspace_z);

    const persistence = try openStore(ctx, db);
    defer lib.smithers_persistence_close(persistence);

    const json = lib.smithers_persistence_load_sessions(persistence, workspace_z.ptr);
    defer lib.smithers_string_free(json);
    try ctx.writeJsonRaw(lib.stringSlice(json));
}

fn save(ctx: *Context, raw_args: []const []const u8) !void {
    const options = try parseOptions(ctx, raw_args, true);
    const db = options.db orelse return ctx.fail("persistence save requires --db", .{});
    const workspace = options.workspace orelse return ctx.fail("persistence save requires --workspace", .{});
    const input = options.input orelse return ctx.fail("persistence save requires --input -", .{});
    if (!std.mem.eql(u8, input, "-")) return ctx.fail("only --input - is supported", .{});

    const stdin = std.fs.File.stdin();
    const sessions_json = try stdin.readToEndAlloc(ctx.allocator, 16 * 1024 * 1024);
    defer ctx.allocator.free(sessions_json);
    const sessions_z = try ctx.allocator.dupeZ(u8, std.mem.trim(u8, sessions_json, &std.ascii.whitespace));
    defer ctx.allocator.free(sessions_z);
    const workspace_z = try ctx.allocator.dupeZ(u8, workspace);
    defer ctx.allocator.free(workspace_z);

    const persistence = try openStore(ctx, db);
    defer lib.smithers_persistence_close(persistence);

    const err = lib.smithers_persistence_save_sessions(persistence, workspace_z.ptr, sessions_z.ptr);
    defer lib.smithers_error_free(err);
    if (err.code != 0) {
        const message = lib.errorMessage(err);
        return ctx.fail("persistence save failed: {s}", .{if (message.len == 0) "unknown error" else message});
    }

    if (ctx.globals.json) {
        try ctx.writeJson(.{ .ok = true });
    } else {
        try ctx.stdout.writeAll("ok\n");
    }
}
