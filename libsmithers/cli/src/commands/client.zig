const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage:
    \\  smithers-cli client call <METHOD> [--args '<JSON>']
    \\  smithers-cli client stream <METHOD> [--args '<JSON>']
    \\
    \\Invoke the generic SmithersClient ABI surface.
;

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0 or args_pkg.isHelp(args[0])) {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    }

    const subcommand = args[0];
    if (std.mem.eql(u8, subcommand, "call")) return call(ctx, args[1..]);
    if (std.mem.eql(u8, subcommand, "stream")) return stream(ctx, args[1..]);
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
        if (args_pkg.isHelp(arg)) {
            try ctx.stdout.writeAll(usage ++ "\n");
            return error.CliFailure;
        }
        if (try parser.optionValue(arg, "args")) |value| {
            args_json = value;
            continue;
        }
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

    while (true) {
        lib.smithers_app_tick(app);
        const ev = lib.smithers_event_stream_next(event_stream);
        defer lib.smithers_event_free(ev);
        switch (ev.tag) {
            .json => {
                try ctx.stdout.writeAll(lib.stringSlice(ev.payload));
                try ctx.stdout.writeByte('\n');
            },
            .err => return ctx.fail("stream event error: {s}", .{lib.stringSlice(ev.payload)}),
            .end => return,
            .none => std.Thread.sleep(100 * std.time.ns_per_ms),
        }
    }
}
