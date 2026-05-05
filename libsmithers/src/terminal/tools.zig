const std = @import("std");
const ffi = @import("../ffi.zig");

pub const default_nvim_paths = [_][]const u8{
    "/opt/homebrew/bin/nvim",
    "/usr/local/bin/nvim",
    "/usr/bin/nvim",
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
    return null;
}

fn executablePath(
    allocator: std.mem.Allocator,
    executable_name: []const u8,
    args: std.json.Value,
    fallback_paths: ?[]const []const u8,
) !?[]u8 {
    var seen: std.ArrayList([]u8) = .empty;
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

fn jsonString(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(text, .{})});
}

fn jsonNull(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "null");
}

fn optionalJsonString(allocator: std.mem.Allocator, value: ?[]const u8) ![]u8 {
    return if (value) |text| jsonString(allocator, text) else jsonNull(allocator);
}
