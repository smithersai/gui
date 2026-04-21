const std = @import("std");
const args_pkg = @import("../args.zig");
const Context = @import("../context.zig").Context;
const lib = @import("../libsmithers.zig");

pub const usage =
    \\Usage:
    \\  smithers-cli session new --kind <terminal|chat|run-inspect|workflow|memory|dashboard> [--workspace PATH] [--target ID]
    \\  smithers-cli session title <SESSION_ID>
    \\
    \\Create a transient libsmithers session or resolve a transient session title.
;

const id_prefix = "transient:";

pub fn run(ctx: *Context, args: []const []const u8) !void {
    if (args.len == 0 or args_pkg.isHelp(args[0])) {
        try ctx.stdout.writeAll(usage ++ "\n");
        return;
    }

    const subcommand = args[0];
    if (std.mem.eql(u8, subcommand, "new")) return new(ctx, args[1..]);
    if (std.mem.eql(u8, subcommand, "title")) return title(ctx, args[1..]);
    return ctx.fail("unknown session subcommand: {s}", .{subcommand});
}

fn new(ctx: *Context, raw_args: []const []const u8) !void {
    var parser = args_pkg.Parser.init(raw_args);
    var kind: ?lib.SessionKind = null;
    var workspace: ?[]const u8 = null;
    var target: ?[]const u8 = null;

    while (parser.next()) |arg| {
        if (args_pkg.isHelp(arg)) {
            try ctx.stdout.writeAll(usage ++ "\n");
            return;
        }
        if (try parser.optionValue(arg, "kind")) |value| {
            kind = parseKind(value) orelse return ctx.fail("invalid session kind: {s}", .{value});
            continue;
        }
        if (try parser.optionValue(arg, "workspace")) |value| {
            workspace = value;
            continue;
        }
        if (try parser.optionValue(arg, "target")) |value| {
            target = value;
            continue;
        }
        return args_pkg.rejectUnexpected(ctx, arg);
    }

    const session_kind = kind orelse return ctx.fail("session new requires --kind", .{});
    try createAndPrint(ctx, session_kind, workspace, target, true);
}

fn title(ctx: *Context, raw_args: []const []const u8) !void {
    if (raw_args.len != 1) return ctx.fail("session title requires exactly one session id", .{});
    var descriptor = try decodeDescriptor(ctx, raw_args[0]);
    defer descriptor.deinit(ctx.allocator);
    try createAndPrint(ctx, descriptor.kind, descriptor.workspace, descriptor.target, false);
}

fn createAndPrint(
    ctx: *Context,
    session_kind: lib.SessionKind,
    workspace: ?[]const u8,
    target: ?[]const u8,
    include_metadata: bool,
) !void {
    const workspace_z = if (workspace) |value| try ctx.allocator.dupeZ(u8, value) else null;
    defer if (workspace_z) |value| ctx.allocator.free(value);
    const target_z = if (target) |value| try ctx.allocator.dupeZ(u8, value) else null;
    defer if (target_z) |value| ctx.allocator.free(value);

    const app = try ctx.makeApp();
    defer lib.smithers_app_free(app);

    const session = lib.smithers_session_new(app, .{
        .kind = session_kind,
        .workspace_path = if (workspace_z) |value| value.ptr else null,
        .target_id = if (target_z) |value| value.ptr else null,
    });
    if (session == null) return ctx.fail("failed to create smithers session", .{});
    defer lib.smithers_session_free(session);

    const title_string = lib.smithers_session_title(session);
    defer lib.smithers_string_free(title_string);
    const title_value = lib.stringSlice(title_string);

    if (!include_metadata) {
        if (ctx.globals.json) {
            try ctx.writeJson(.{ .title = title_value });
        } else {
            try ctx.stdout.print("{s}\n", .{title_value});
        }
        return;
    }

    const session_id = try encodeDescriptor(ctx.allocator, session_kind, workspace, target);
    defer ctx.allocator.free(session_id);

    if (ctx.globals.json) {
        try ctx.writeJson(.{
            .sessionId = session_id,
            .kind = lib.kindName(session_kind),
            .title = title_value,
            .workspace = workspace,
            .target = target,
        });
    } else {
        try ctx.stdout.print("sessionId: {s}\n", .{session_id});
        try ctx.stdout.print("kind: {s}\n", .{lib.kindName(session_kind)});
        try ctx.stdout.print("title: {s}\n", .{title_value});
        if (workspace) |value| try ctx.stdout.print("workspace: {s}\n", .{value});
        if (target) |value| try ctx.stdout.print("target: {s}\n", .{value});
    }
}

fn parseKind(value: []const u8) ?lib.SessionKind {
    if (std.mem.eql(u8, value, "terminal")) return .terminal;
    if (std.mem.eql(u8, value, "chat")) return .chat;
    if (std.mem.eql(u8, value, "run-inspect")) return .run_inspect;
    if (std.mem.eql(u8, value, "workflow")) return .workflow;
    if (std.mem.eql(u8, value, "memory")) return .memory;
    if (std.mem.eql(u8, value, "dashboard")) return .dashboard;
    return null;
}

fn encodeDescriptor(
    allocator: std.mem.Allocator,
    kind: lib.SessionKind,
    workspace: ?[]const u8,
    target: ?[]const u8,
) ![]u8 {
    var json_out: std.Io.Writer.Allocating = .init(allocator);
    defer json_out.deinit();
    try std.json.Stringify.value(.{
        .kind = lib.kindName(kind),
        .workspace = workspace,
        .target = target,
    }, .{}, &json_out.writer);

    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(json_out.written().len);
    var out = try allocator.alloc(u8, id_prefix.len + encoded_len);
    @memcpy(out[0..id_prefix.len], id_prefix);
    _ = std.base64.url_safe_no_pad.Encoder.encode(out[id_prefix.len..], json_out.written());
    return out;
}

const Descriptor = struct {
    kind: lib.SessionKind,
    workspace: ?[]u8,
    target: ?[]u8,

    fn deinit(self: *Descriptor, allocator: std.mem.Allocator) void {
        if (self.workspace) |value| allocator.free(value);
        if (self.target) |value| allocator.free(value);
        self.* = .{ .kind = .terminal, .workspace = null, .target = null };
    }
};

fn decodeDescriptor(ctx: *Context, id: []const u8) !Descriptor {
    if (!std.mem.startsWith(u8, id, id_prefix)) {
        try ctx.fail("unsupported session id; expected value produced by `session new`", .{});
        unreachable;
    }
    const encoded = id[id_prefix.len..];
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(encoded) catch {
        try ctx.fail("invalid session id encoding", .{});
        unreachable;
    };
    const decoded = try ctx.allocator.alloc(u8, decoded_len);
    defer ctx.allocator.free(decoded);
    std.base64.url_safe_no_pad.Decoder.decode(decoded, encoded) catch {
        try ctx.fail("invalid session id encoding", .{});
        unreachable;
    };

    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, decoded, .{}) catch {
        try ctx.fail("invalid session id payload", .{});
        unreachable;
    };
    defer parsed.deinit();

    const kind_text = jsonObjectString(parsed.value, "kind") orelse {
        try ctx.fail("invalid session id payload: missing kind", .{});
        unreachable;
    };
    const session_kind = parseKind(kind_text) orelse {
        try ctx.fail("invalid session id payload: unknown kind {s}", .{kind_text});
        unreachable;
    };

    const workspace_copy = if (jsonObjectString(parsed.value, "workspace")) |value|
        try ctx.allocator.dupe(u8, value)
    else
        null;
    errdefer if (workspace_copy) |value| ctx.allocator.free(value);
    const target_copy = if (jsonObjectString(parsed.value, "target")) |value|
        try ctx.allocator.dupe(u8, value)
    else
        null;

    return .{
        .kind = session_kind,
        .workspace = workspace_copy,
        .target = target_copy,
    };
}

fn jsonObjectString(value: std.json.Value, name: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(name) orelse return null;
    return switch (field) {
        .string => |text| text,
        else => null,
    };
}

test "session kind parser" {
    try std.testing.expectEqual(lib.SessionKind.terminal, parseKind("terminal").?);
    try std.testing.expectEqual(lib.SessionKind.run_inspect, parseKind("run-inspect").?);
    try std.testing.expect(parseKind("run_inspect") == null);
}

test "session descriptor round trip" {
    const allocator = std.testing.allocator;
    const encoded = try encodeDescriptor(allocator, .chat, "/tmp/repo", "run-1");
    defer allocator.free(encoded);

    var stdout_buffer: [1024]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);
    var ctx = Context{
        .allocator = allocator,
        .globals = .{},
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
    };
    var decoded = try decodeDescriptor(&ctx, encoded);
    defer decoded.deinit(allocator);
    try std.testing.expectEqual(lib.SessionKind.chat, decoded.kind);
    try std.testing.expectEqualStrings("/tmp/repo", decoded.workspace.?);
    try std.testing.expectEqualStrings("run-1", decoded.target.?);
}
