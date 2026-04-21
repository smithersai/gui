const std = @import("std");
const cwd = @import("cwd.zig");

pub const RecentWorkspace = struct {
    path: []const u8,
    displayName: []const u8,
    lastOpened: i64,
};

pub fn workspaceFromLaunch(
    allocator: std.mem.Allocator,
    arguments: []const []const u8,
    environment_open_workspace: ?[]const u8,
) !?[]u8 {
    if (environment_open_workspace) |env| {
        if (env.len > 0) {
            const current = try std.process.getCwdAlloc(allocator);
            defer allocator.free(current);
            return try cwd.standardizeAbsolute(allocator, env, current);
        }
    }

    var i: usize = 1;
    while (i < arguments.len) : (i += 1) {
        const arg = arguments[i];
        if (std.mem.startsWith(u8, arg, "-")) {
            i += 1;
            continue;
        }
        if (std.mem.eql(u8, arg, "YES") or std.mem.eql(u8, arg, "NO")) continue;

        const current = try std.process.getCwdAlloc(allocator);
        defer allocator.free(current);
        return try cwd.standardizeAbsolute(allocator, arg, current);
    }

    return null;
}

pub fn displayName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

pub fn nowSeconds() i64 {
    return @intCast(std.time.timestamp());
}
