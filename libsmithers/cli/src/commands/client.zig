const std = @import("std");
const builtin = @import("builtin");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage:
    \\  smithers-cli client call <METHOD> [--args '<JSON>']
    \\  smithers-cli client stream <METHOD> [--args '<JSON>']
    \\
    \\Options:
    \\  -a, --args <JSON>  JSON argument object. Defaults to {}.
    \\  -h, --help         Show help.
    \\
    \\Invoke the generic SmithersClient ABI surface.
    \\
    \\Examples:
    \\  smithers-cli client call listWorkflows
    \\  smithers-cli client stream streamDevTools --args '{"runId":"x"}'
;

var stream_interrupted = std.atomic.Value(bool).init(false);

fn handleSigInt(_: i32) callconv(.c) void {
    stream_interrupted.store(true, .seq_cst);
}

const SignalGuard = struct {
    old: ?std.posix.Sigaction = null,

    fn install() SignalGuard {
        if (builtin.os.tag == .windows) return .{};
        stream_interrupted.store(false, .seq_cst);
        const act: std.posix.Sigaction = .{
            .handler = .{ .handler = handleSigInt },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        var old: std.posix.Sigaction = undefined;
        std.posix.sigaction(std.posix.SIG.INT, &act, &old);
        return .{ .old = old };
    }

    fn deinit(self: *SignalGuard) void {
        if (builtin.os.tag == .windows) return;
        if (self.old) |old| std.posix.sigaction(std.posix.SIG.INT, &old, null);
    }
};

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
    if (std.mem.eql(u8, subcommand, "call")) return call(ctx, parser.remaining());
    if (std.mem.eql(u8, subcommand, "stream")) return stream(ctx, parser.remaining());
    return ctx.fail("unknown client subcommand: {s}", .{subcommand});
}

const Parsed = struct {
    method: []const u8,
    args_json: []const u8,
};

fn parseMethodArgs(ctx: *Context, raw_args: []const []const u8, verb: []const u8) !Parsed {
    var parser = args_pkg.Parser.init(raw_args);
    var method: ?[]const u8 = null;
    var args_json: []const u8 = "{}";

    while (parser.next()) |arg| {
        if (try parser.optionValueAny(arg, "args", 'a')) |value| {
            args_json = value;
            continue;
        }
        if (args_pkg.isGlobalFlag(arg)) continue;
        if (std.mem.startsWith(u8, arg, "-")) {
            try args_pkg.rejectUnexpected(ctx, arg);
            unreachable;
        }
        if (method != null) {
            try ctx.fail("client {s} accepts exactly one method", .{verb});
            unreachable;
        }
        method = arg;
    }

    const method_value = method orelse {
        try ctx.fail("client {s} requires a method", .{verb});
        unreachable;
    };
    return .{
        .method = method_value,
        .args_json = args_json,
    };
}

fn call(ctx: *Context, raw_args: []const []const u8) !void {
    const parsed = try parseMethodArgs(ctx, raw_args, "call");
    const method_z = try ctx.allocator.dupeZ(u8, parsed.method);
    defer ctx.allocator.free(method_z);
    const args_z = try ctx.allocator.dupeZ(u8, parsed.args_json);
    defer ctx.allocator.free(args_z);

    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);
    const client = try ctx.makeClient(app);
    defer lib.smithers_client_free(client);

    var err: lib.Error = .{ .code = 0, .msg = null };
    const result = lib.smithers_client_call(client, method_z.ptr, args_z.ptr, &err);
    defer lib.smithers_string_free(result);
    defer lib.smithers_error_free(err);
    if (err.code != 0) {
        const message = lib.errorMessage(err);
        return ctx.fail("client call failed: {s}", .{if (message.len == 0) "unknown error" else message});
    }

    try ctx.writeJsonRaw(lib.stringSlice(result));
}

fn stream(ctx: *Context, raw_args: []const []const u8) !void {
    const parsed = try parseMethodArgs(ctx, raw_args, "stream");
    const method_z = try ctx.allocator.dupeZ(u8, parsed.method);
    defer ctx.allocator.free(method_z);
    const args_z = try ctx.allocator.dupeZ(u8, parsed.args_json);
    defer ctx.allocator.free(args_z);

    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);
    const client = try ctx.makeClient(app);
    defer lib.smithers_client_free(client);

    var err: lib.Error = .{ .code = 0, .msg = null };
    const event_stream = lib.smithers_client_stream(client, method_z.ptr, args_z.ptr, &err);
    defer lib.smithers_error_free(err);
    if (err.code != 0) {
        const message = lib.errorMessage(err);
        return ctx.fail("client stream failed: {s}", .{if (message.len == 0) "unknown error" else message});
    }
    if (event_stream == null) return ctx.fail("client stream returned no stream", .{});
    defer lib.smithers_event_stream_free(event_stream);

    var signal_guard = SignalGuard.install();
    defer signal_guard.deinit();

    while (true) {
        if (stream_interrupted.load(.seq_cst)) {
            try ctx.stderr.writeAll("interrupted\n");
            return error.CliInterrupted;
        }
        lib.smithers_app_tick(app);
        const ev = lib.smithers_event_stream_next(event_stream);
        defer lib.smithers_event_free(ev);
        switch (ev.tag) {
            .json => {
                try ctx.stdout.writeAll(lib.stringSlice(ev.payload));
                try ctx.stdout.writeByte('\n');
                try ctx.stdout.flush();
            },
            .err => return ctx.fail("stream event error: {s}", .{lib.stringSlice(ev.payload)}),
            .end => return,
            .none => std.Thread.sleep(100 * std.time.ns_per_ms),
        }
    }
}
