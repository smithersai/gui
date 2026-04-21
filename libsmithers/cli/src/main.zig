const std = @import("std");
const clap = @import("clap");

const context = @import("context.zig");
const Context = context.Context;
const Globals = context.Globals;
const lib = @import("libsmithers.zig");

const info_cmd = @import("commands/info.zig");
const cwd_cmd = @import("commands/cwd.zig");
const workspace_cmd = @import("commands/workspace.zig");
const slash_cmd = @import("commands/slash.zig");
const palette_cmd = @import("commands/palette.zig");
const session_cmd = @import("commands/session.zig");
const client_cmd = @import("commands/client.zig");
const persistence_cmd = @import("commands/persistence.zig");
const event_cmd = @import("commands/event.zig");

const top_level_params = clap.parseParamsComptime(
    \\--json       Emit structured JSON where applicable.
    \\--verbose    Emit additional diagnostic output where applicable.
    \\-h, --help   Show help.
    \\--version    Show version.
    \\<command>
    \\
);

pub const Command = enum {
    info,
    cwd,
    workspace,
    slash,
    palette,
    session,
    client,
    persistence,
    event,
};

pub const Invocation = struct {
    globals: Globals = .{},
    help: bool = false,
    version: bool = false,
    command: ?Command = null,
    rest: []const []const u8 = &.{},
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const allocator = debug_allocator.allocator();
    defer _ = debug_allocator.deinit();

    const argv = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, argv);

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

    const code = try runArgs(
        allocator,
        if (argv.len > 0) argv[1..] else &.{},
        &stdout_writer.interface,
        &stderr_writer.interface,
    );

    try stdout_writer.interface.flush();
    try stderr_writer.interface.flush();
    std.process.exit(code);
}

pub fn runArgs(
    allocator: std.mem.Allocator,
    raw_args: []const []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    _ = top_level_params;

    const global_hints = detectGlobalHints(raw_args);
    const invocation = parseInvocation(raw_args) catch |err| {
        var ctx = Context{ .allocator = allocator, .globals = global_hints, .stdout = stdout, .stderr = stderr };
        const message = switch (err) {
            error.UnknownCommand => "unknown command",
            error.UnknownGlobalOption => "unknown global option",
        };
        try ctx.writeError(message);
        return 1;
    };

    var ctx = Context{
        .allocator = allocator,
        .globals = invocation.globals,
        .stdout = stdout,
        .stderr = stderr,
    };

    if (lib.smithers_init(0, null) != 0) {
        try ctx.writeError("libsmithers initialization failed");
        return 1;
    }

    if (invocation.version) {
        try printVersion(&ctx);
        return 0;
    }

    if (invocation.command == null) {
        try printHelp(&ctx);
        return 0;
    }

    const command = invocation.command.?;
    if (invocation.help) {
        try dispatch(&ctx, command, &.{"--help"});
        return 0;
    }

    dispatch(&ctx, command, invocation.rest) catch |err| {
        if (err == error.CliFailure) return 1;
        try ctx.writeError(@errorName(err));
        return 1;
    };
    return 0;
}

fn detectGlobalHints(raw_args: []const []const u8) Globals {
    var globals = Globals{};
    for (raw_args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) globals.json = true;
        if (std.mem.eql(u8, arg, "--verbose")) globals.verbose = true;
    }
    return globals;
}

pub fn parseInvocation(raw_args: []const []const u8) !Invocation {
    var invocation = Invocation{};

    var i: usize = 0;
    while (i < raw_args.len) : (i += 1) {
        const arg = raw_args[i];
        if (std.mem.eql(u8, arg, "--json")) {
            invocation.globals.json = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--verbose")) {
            invocation.globals.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            invocation.help = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--version")) {
            invocation.version = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "-")) return error.UnknownGlobalOption;

        invocation.command = std.meta.stringToEnum(Command, arg) orelse return error.UnknownCommand;
        invocation.rest = raw_args[i + 1 ..];
        return invocation;
    }

    return invocation;
}

fn dispatch(ctx: *Context, command: Command, args: []const []const u8) !void {
    return switch (command) {
        .info => info_cmd.run(ctx, args),
        .cwd => cwd_cmd.run(ctx, args),
        .workspace => workspace_cmd.run(ctx, args),
        .slash => slash_cmd.run(ctx, args),
        .palette => palette_cmd.run(ctx, args),
        .session => session_cmd.run(ctx, args),
        .client => client_cmd.run(ctx, args),
        .persistence => persistence_cmd.run(ctx, args),
        .event => event_cmd.run(ctx, args),
    };
}

fn printVersion(ctx: *Context) !void {
    const info = lib.smithers_info();
    const version = std.mem.sliceTo(info.version, 0);
    const commit = std.mem.sliceTo(info.commit, 0);
    const platform = lib.platformName(info.platform);

    if (ctx.globals.json) {
        try ctx.writeJson(.{
            .name = "smithers-cli",
            .version = version,
            .libsmithers = .{
                .version = version,
                .commit = commit,
                .platform = platform,
            },
        });
        return;
    }

    try ctx.stdout.print("smithers-cli {s}\n", .{version});
    try ctx.stdout.print("libsmithers {s} ({s}, {s})\n", .{ version, commit, platform });
}

fn printHelp(ctx: *Context) !void {
    try ctx.stdout.writeAll(
        \\Usage: smithers-cli [--json] [--verbose] <command> [args]
        \\
        \\Standalone command-line frontend for libsmithers.
        \\
        \\Global flags:
        \\  --json       Emit structured JSON where applicable.
        \\  --verbose    Emit additional diagnostic output where applicable.
        \\  -h, --help   Show help.
        \\  --version    Show version.
        \\
        \\Commands:
        \\  info
        \\  cwd
        \\  workspace
        \\  slash
        \\  palette
        \\  session
        \\  client
        \\  persistence
        \\  event
        \\
        \\Use `smithers-cli <command> --help` for command-specific usage.
        \\
    );
}

test "parse top-level globals and command" {
    const inv = try parseInvocation(&.{ "--json", "--verbose", "info" });
    try std.testing.expect(inv.globals.json);
    try std.testing.expect(inv.globals.verbose);
    try std.testing.expectEqual(Command.info, inv.command.?);
    try std.testing.expectEqual(@as(usize, 0), inv.rest.len);
}

test "parse nested command rest" {
    const inv = try parseInvocation(&.{ "cwd", "resolve", "." });
    try std.testing.expectEqual(Command.cwd, inv.command.?);
    try std.testing.expectEqual(@as(usize, 2), inv.rest.len);
    try std.testing.expectEqualStrings("resolve", inv.rest[0]);
    try std.testing.expectEqualStrings(".", inv.rest[1]);
}

test "parse global version without command" {
    const inv = try parseInvocation(&.{"--version"});
    try std.testing.expect(inv.version);
    try std.testing.expect(inv.command == null);
}

test "parse rejects unknown command" {
    try std.testing.expectError(error.UnknownCommand, parseInvocation(&.{"bogus"}));
}
