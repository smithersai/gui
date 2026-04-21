const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage:
    \\  smithers-cli persistence load --db <PATH> --workspace <PATH>
    \\  smithers-cli persistence save --db <PATH> --workspace <PATH> --input -
    \\
    \\Options:
    \\  -d, --db <PATH>         SQLite database path.
    \\  -w, --workspace <PATH>  Workspace path key.
    \\  -i, --input -           Read session JSON from stdin.
    \\  -h, --help              Show help.
    \\
    \\Load or save persisted session JSON through libsmithers.
    \\
    \\Examples:
    \\  smithers-cli persistence load -d sessions.sqlite -w /repo
    \\  printf '[]' | smithers-cli persistence save -d sessions.sqlite -w /repo -i -
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
    if (std.mem.eql(u8, subcommand, "load")) return load(ctx, parser.remaining());
    if (std.mem.eql(u8, subcommand, "save")) return save(ctx, parser.remaining());
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
        if (try parser.optionValueAny(arg, "db", 'd')) |value| {
            options.db = value;
            continue;
        }
        if (try parser.optionValueAny(arg, "workspace", 'w')) |value| {
            options.workspace = value;
            continue;
        }
        if (allow_input) {
            if (try parser.optionValueAny(arg, "input", 'i')) |value| {
                options.input = value;
                continue;
            }
        }
        if (args_pkg.isGlobalFlag(arg)) continue;
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
