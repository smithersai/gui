const std = @import("std");
const ffi = @import("../ffi.zig");

pub const default_tmux_paths = [_][]const u8{
    "/opt/homebrew/bin/tmux",
    "/usr/local/bin/tmux",
    "/usr/bin/tmux",
};

pub const default_nvim_paths = [_][]const u8{
    "/opt/homebrew/bin/nvim",
    "/usr/local/bin/nvim",
    "/usr/bin/nvim",
};

const CommandResult = struct {
    success: bool,
    output: []u8,
    err: []u8,

    fn deinit(self: CommandResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
        allocator.free(self.err);
    }
};

pub fn call(allocator: std.mem.Allocator, method: []const u8, args: std.json.Value) !?[]u8 {
    if (std.mem.eql(u8, method, "terminalExecutablePath")) {
        const executable_name = ffi.jsonObjectString(args, "name") orelse return try jsonNull(allocator);
        const found = try executablePath(allocator, executable_name, args, null);
        defer if (found) |path| allocator.free(path);
        return try optionalJsonString(allocator, found);
    }
    if (std.mem.eql(u8, method, "terminalIsExecutableAvailable")) {
        const executable_name = ffi.jsonObjectString(args, "name") orelse return try allocator.dupe(u8, "false");
        const found = try executablePath(allocator, executable_name, args, null);
        defer if (found) |path| allocator.free(path);
        return try allocator.dupe(u8, if (found != null) "true" else "false");
    }
    if (std.mem.eql(u8, method, "neovimExecutablePath")) {
        const found = try executablePath(allocator, "nvim", args, default_nvim_paths[0..]);
        defer if (found) |path| allocator.free(path);
        return try optionalJsonString(allocator, found);
    }
    if (std.mem.eql(u8, method, "neovimIsAvailable")) {
        const found = try executablePath(allocator, "nvim", args, default_nvim_paths[0..]);
        defer if (found) |path| allocator.free(path);
        return try allocator.dupe(u8, if (found != null) "true" else "false");
    }
    if (std.mem.eql(u8, method, "tmuxExecutablePath")) {
        const found = try executablePath(allocator, "tmux", args, default_tmux_paths[0..]);
        defer if (found) |path| allocator.free(path);
        return try optionalJsonString(allocator, found);
    }
    if (std.mem.eql(u8, method, "tmuxIsAvailable")) {
        const found = try executablePath(allocator, "tmux", args, default_tmux_paths[0..]);
        defer if (found) |path| allocator.free(path);
        return try allocator.dupe(u8, if (found != null) "true" else "false");
    }
    if (std.mem.eql(u8, method, "tmuxSocketName")) {
        const cwd = ffi.jsonObjectString(args, "workingDirectory") orelse "";
        const hash = try stableHash(allocator, cwd);
        defer allocator.free(hash);
        const value = try std.fmt.allocPrint(allocator, "smithers-{s}", .{hash});
        defer allocator.free(value);
        return try jsonString(allocator, value);
    }
    if (std.mem.eql(u8, method, "tmuxRootSurfaceId")) {
        const terminal_id = ffi.jsonObjectString(args, "terminalId") orelse "";
        const value = try std.fmt.allocPrint(allocator, "{s}-root", .{terminal_id});
        defer allocator.free(value);
        return try jsonString(allocator, value);
    }
    if (std.mem.eql(u8, method, "tmuxSessionName")) {
        const surface_id = ffi.jsonObjectString(args, "surfaceId") orelse "";
        const value = try sessionName(allocator, surface_id);
        defer allocator.free(value);
        return try jsonString(allocator, value);
    }
    if (std.mem.eql(u8, method, "tmuxAttach")) {
        const executable = try executablePath(allocator, "tmux", args, default_tmux_paths[0..]);
        defer if (executable) |path| allocator.free(path);
        const socket_name = normalized(ffi.jsonObjectString(args, "socketName"));
        const session_name = normalized(ffi.jsonObjectString(args, "sessionName"));
        if (executable == null or socket_name == null or session_name == null) return try jsonNull(allocator);
        const command = try attachCommand(allocator, executable.?, socket_name.?, session_name.?);
        defer allocator.free(command);
        return try jsonString(allocator, command);
    }
    if (std.mem.eql(u8, method, "tmuxEnsureSession")) {
        return try tmuxEnsureSession(allocator, args);
    }
    if (std.mem.eql(u8, method, "tmuxTerminateSession")) {
        return try tmuxTerminateSession(allocator, args);
    }
    if (std.mem.eql(u8, method, "tmuxCapturePane")) {
        return try tmuxCapturePane(allocator, args);
    }
    if (std.mem.eql(u8, method, "tmuxSendText")) {
        return try tmuxSendText(allocator, args);
    }
    return null;
}

fn tmuxEnsureSession(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const executable = try executablePath(allocator, "tmux", args, default_tmux_paths[0..]) orelse {
        return try allocator.dupe(u8, "false");
    };
    defer allocator.free(executable);

    const socket_name = normalized(ffi.jsonObjectString(args, "socketName")) orelse return try allocator.dupe(u8, "false");
    const session_name = normalized(ffi.jsonObjectString(args, "sessionName")) orelse return try allocator.dupe(u8, "false");

    const has_args = [_][]const u8{ executable, "-L", socket_name, "has-session", "-t", session_name };
    const has = try runCommand(allocator, &has_args);
    defer has.deinit(allocator);
    if (has.success) {
        try renameWindow(allocator, executable, socket_name, session_name, ffi.jsonObjectString(args, "title"));
        return try allocator.dupe(u8, "true");
    }

    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ executable, "-L", socket_name, "new-session", "-d", "-s", session_name });
    if (normalized(ffi.jsonObjectString(args, "title"))) |title| try argv.appendSlice(allocator, &.{ "-n", title });
    if (normalized(ffi.jsonObjectString(args, "workingDirectory"))) |cwd| try argv.appendSlice(allocator, &.{ "-c", cwd });
    if (normalized(ffi.jsonObjectString(args, "command"))) |command| try argv.append(allocator, command);

    const result = try runCommand(allocator, argv.items);
    defer result.deinit(allocator);
    return try allocator.dupe(u8, if (result.success) "true" else "false");
}

fn tmuxTerminateSession(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const executable = try executablePath(allocator, "tmux", args, default_tmux_paths[0..]) orelse return try allocator.dupe(u8, "true");
    defer allocator.free(executable);
    const socket_name = normalized(ffi.jsonObjectString(args, "socketName")) orelse return try allocator.dupe(u8, "true");
    const session_name = normalized(ffi.jsonObjectString(args, "sessionName")) orelse return try allocator.dupe(u8, "true");

    const argv = [_][]const u8{ executable, "-L", socket_name, "kill-session", "-t", session_name };
    const result = try runCommand(allocator, &argv);
    defer result.deinit(allocator);
    return try allocator.dupe(u8, if (result.success) "true" else "false");
}

fn tmuxCapturePane(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const executable = try executablePath(allocator, "tmux", args, default_tmux_paths[0..]) orelse {
        return try statusResult(allocator, false, "tmuxUnavailable", "tmux is not available.", null);
    };
    defer allocator.free(executable);
    const socket_name = normalized(ffi.jsonObjectString(args, "socketName")) orelse {
        return try statusResult(allocator, false, "commandFailed", "socket name is required.", null);
    };
    const session_name = normalized(ffi.jsonObjectString(args, "sessionName")) orelse {
        return try statusResult(allocator, false, "commandFailed", "session name is required.", null);
    };
    const lines = @max(ffi.jsonObjectInteger(args, "lines") orelse 200, 1);
    const start_line = try std.fmt.allocPrint(allocator, "-{}", .{lines});
    defer allocator.free(start_line);

    const argv = [_][]const u8{ executable, "-L", socket_name, "capture-pane", "-p", "-S", start_line, "-t", session_name };
    const result = try runCommand(allocator, &argv);
    defer result.deinit(allocator);
    if (!result.success) {
        return try statusResult(allocator, false, "commandFailed", result.err, null);
    }
    return try statusResult(allocator, true, null, null, result.output);
}

fn tmuxSendText(allocator: std.mem.Allocator, args: std.json.Value) ![]u8 {
    const executable = try executablePath(allocator, "tmux", args, default_tmux_paths[0..]) orelse {
        return try statusResult(allocator, false, "tmuxUnavailable", "tmux is not available.", null);
    };
    defer allocator.free(executable);
    const socket_name = normalized(ffi.jsonObjectString(args, "socketName")) orelse {
        return try statusResult(allocator, false, "commandFailed", "socket name is required.", null);
    };
    const session_name = normalized(ffi.jsonObjectString(args, "sessionName")) orelse {
        return try statusResult(allocator, false, "commandFailed", "session name is required.", null);
    };
    const text = ffi.jsonObjectString(args, "text") orelse "";
    const enter = ffi.jsonObjectBool(args, "enter") orelse false;

    const literal_args = [_][]const u8{ executable, "-L", socket_name, "send-keys", "-t", session_name, "-l", "--", text };
    const literal = try runCommand(allocator, &literal_args);
    defer literal.deinit(allocator);
    if (!literal.success) {
        return try statusResult(allocator, false, "commandFailed", literal.err, null);
    }
    if (enter) {
        const enter_args = [_][]const u8{ executable, "-L", socket_name, "send-keys", "-t", session_name, "Enter" };
        const enter_result = try runCommand(allocator, &enter_args);
        defer enter_result.deinit(allocator);
        if (!enter_result.success) {
            return try statusResult(allocator, false, "commandFailed", enter_result.err, null);
        }
    }
    return try statusResult(allocator, true, null, null, null);
}

fn renameWindow(
    allocator: std.mem.Allocator,
    executable: []const u8,
    socket_name: []const u8,
    session_name: []const u8,
    title_raw: ?[]const u8,
) !void {
    const title = normalized(title_raw) orelse return;
    const argv = [_][]const u8{ executable, "-L", socket_name, "rename-window", "-t", session_name, title };
    const result = try runCommand(allocator, &argv);
    result.deinit(allocator);
}

fn executablePath(
    allocator: std.mem.Allocator,
    executable_name: []const u8,
    args: std.json.Value,
    fallback_paths: ?[]const []const u8,
) !?[]u8 {
    var seen = std.ArrayList([]u8).empty;
    defer {
        for (seen.items) |item| allocator.free(item);
        seen.deinit(allocator);
    }

    if (pathFromEnvironment(args)) |path| {
        var parts = std.mem.splitScalar(u8, path, ':');
        while (parts.next()) |directory| {
            if (directory.len == 0) continue;
            const candidate = try std.fs.path.join(allocator, &.{ directory, executable_name });
            defer allocator.free(candidate);
            if (try executableCandidate(allocator, &seen, candidate)) |resolved| return resolved;
        }
    }

    if (jsonArray(args, "commonPaths")) |paths| {
        for (paths) |path| {
            if (path == .string) {
                if (try executableCandidate(allocator, &seen, path.string)) |resolved| return resolved;
            }
        }
    } else if (fallback_paths) |paths| {
        for (paths) |path| {
            if (try executableCandidate(allocator, &seen, path)) |resolved| return resolved;
        }
    }

    return null;
}

fn pathFromEnvironment(args: std.json.Value) ?[]const u8 {
    if (args == .object) {
        if (args.object.get("environment")) |env| {
            if (env == .object) {
                if (env.object.get("PATH")) |path| {
                    if (path == .string) return path.string;
                }
            }
        }
    }
    return std.posix.getenv("PATH");
}

fn jsonArray(args: std.json.Value, key: []const u8) ?[]std.json.Value {
    if (args != .object) return null;
    const value = args.object.get(key) orelse return null;
    return switch (value) {
        .array => |items| items.items,
        else => null,
    };
}

fn executableCandidate(
    allocator: std.mem.Allocator,
    seen: *std.ArrayList([]u8),
    raw_candidate: []const u8,
) !?[]u8 {
    const candidate = std.mem.trim(u8, raw_candidate, &std.ascii.whitespace);
    if (candidate.len == 0) return null;
    for (seen.items) |item| {
        if (std.mem.eql(u8, item, candidate)) return null;
    }
    try seen.append(allocator, try allocator.dupe(u8, candidate));
    if (isExecutable(candidate)) return try allocator.dupe(u8, candidate);
    return null;
}

fn isExecutable(path: []const u8) bool {
    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) !CommandResult {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 2 * 1024 * 1024,
    }) catch |err| {
        return .{
            .success = false,
            .output = try allocator.dupe(u8, ""),
            .err = try std.fmt.allocPrint(allocator, "{}", .{err}),
        };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const success = result.term == .Exited and result.term.Exited == 0;
    const err_text = std.mem.trim(u8, result.stderr, &std.ascii.whitespace);
    const stderr_or_term = if (err_text.len > 0) err_text else try std.fmt.allocPrint(allocator, "tmux exited with {any}", .{result.term});
    defer if (err_text.len == 0) allocator.free(stderr_or_term);
    return .{
        .success = success,
        .output = try allocator.dupe(u8, result.stdout),
        .err = try allocator.dupe(u8, if (success and err_text.len == 0) "" else stderr_or_term),
    };
}

fn attachCommand(allocator: std.mem.Allocator, executable: []const u8, socket_name: []const u8, session_name: []const u8) ![]u8 {
    const quoted_executable = try shellQuoted(allocator, executable);
    defer allocator.free(quoted_executable);
    const quoted_socket = try shellQuoted(allocator, socket_name);
    defer allocator.free(quoted_socket);
    const quoted_session = try shellQuoted(allocator, session_name);
    defer allocator.free(quoted_session);
    return std.fmt.allocPrint(
        allocator,
        "{s} -L {s} attach-session -t {s}",
        .{ quoted_executable, quoted_socket, quoted_session },
    );
}

fn sessionName(allocator: std.mem.Allocator, surface_id: []const u8) ![]u8 {
    const sanitized = try sanitizeIdentifier(allocator, surface_id);
    defer allocator.free(sanitized);
    if (sanitized.len == 0) {
        const hash = try stableHash(allocator, surface_id);
        defer allocator.free(hash);
        return std.fmt.allocPrint(allocator, "smt-{s}", .{hash});
    }
    return std.fmt.allocPrint(allocator, "smt-{s}", .{sanitized});
}

fn sanitizeIdentifier(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var previous_dash = false;
    for (value) |byte| {
        const lower = std.ascii.toLower(byte);
        const allowed = std.ascii.isAlphanumeric(lower) or lower == '-' or lower == '_';
        const next = if (allowed) lower else '-';
        if (next == '-') {
            if (previous_dash) continue;
            previous_dash = true;
        } else {
            previous_dash = false;
        }
        try out.append(allocator, next);
    }
    var slice = out.items;
    while (slice.len > 0 and (slice[0] == '-' or slice[0] == '_')) slice = slice[1..];
    while (slice.len > 0 and (slice[slice.len - 1] == '-' or slice[slice.len - 1] == '_')) slice = slice[0 .. slice.len - 1];
    return allocator.dupe(u8, slice);
}

fn stableHash(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var hash: u64 = 14695981039346656037;
    for (value) |byte| {
        hash ^= byte;
        hash *%= 1099511628211;
    }
    return std.fmt.allocPrint(allocator, "{x}", .{hash});
}

fn shellQuoted(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.append(allocator, '\'');
    for (value) |byte| {
        if (byte == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, byte);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn normalized(value: ?[]const u8) ?[]const u8 {
    const raw = value orelse return null;
    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    return if (trimmed.len == 0) null else trimmed;
}

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(text, .{})});
}

fn jsonNull(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "null");
}

fn optionalJsonString(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    return if (value) |text| jsonString(allocator, text) else jsonNull(allocator);
}

fn statusResult(
    allocator: std.mem.Allocator,
    ok: bool,
    code: ?[]const u8,
    message: ?[]const u8,
    output: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(.{
        .ok = ok,
        .code = code,
        .@"error" = message,
        .output = output,
    }, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "tmux names are stable and shell quoted" {
    const hash = try stableHash(std.testing.allocator, "/tmp/project");
    defer std.testing.allocator.free(hash);
    const socket = try std.fmt.allocPrint(std.testing.allocator, "smithers-{s}", .{hash});
    defer std.testing.allocator.free(socket);
    try std.testing.expectEqualStrings("smithers-ebab4cfadaecf751", socket);
    const session = try sessionName(std.testing.allocator, "My Surface#1");
    defer std.testing.allocator.free(session);
    try std.testing.expectEqualStrings("smt-my-surface-1", session);

    const quoted = try shellQuoted(std.testing.allocator, "sock'et");
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'sock'\\''et'", quoted);
}

test "terminal call builds tmux attach command" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "tmux", .data = "" });
    var fake_file = try tmp.dir.openFile("tmux", .{});
    try fake_file.chmod(0o755);
    fake_file.close();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    const fake = try std.fs.path.join(std.testing.allocator, &.{ root, "tmux" });
    defer std.testing.allocator.free(fake);

    const args_json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"environment\":{{\"PATH\":{f}}},\"socketName\":\"sock'et\",\"sessionName\":\"sess\"}}",
        .{std.json.fmt(root, .{})},
    );
    defer std.testing.allocator.free(args_json);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, args_json, .{});
    defer parsed.deinit();
    const result = (try call(std.testing.allocator, "tmuxAttach", parsed.value)).?;
    defer std.testing.allocator.free(result);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "\"'{s}' -L 'sock'\\\\''et' attach-session -t 'sess'\"", .{fake});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, result);
}
