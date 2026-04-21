const std = @import("std");
const ffi = @import("../ffi.zig");

pub fn resolve(allocator: std.mem.Allocator, requested: ?[]const u8) ![]u8 {
    const current = try std.process.getCwdAlloc(allocator);
    defer allocator.free(current);

    const home_raw = std.posix.getenv("HOME") orelse current;
    const home = try standardizeAbsolute(allocator, home_raw, current);
    errdefer allocator.free(home);

    const candidate_raw = candidate: {
        if (requested) |value| {
            const trimmed = std.mem.trim(u8, value, &std.ascii.whitespace);
            if (trimmed.len > 0) break :candidate trimmed;
        }
        break :candidate current;
    };

    const resolved = try standardizeAbsolute(allocator, candidate_raw, current);
    defer allocator.free(resolved);

    if (std.mem.eql(u8, resolved, "/") or !isDirectory(resolved)) {
        return home;
    }

    allocator.free(home);
    return try allocator.dupe(u8, resolved);
}

pub fn resolveC(requested: ?[*:0]const u8) ![]u8 {
    const req = if (requested) |ptr| std.mem.sliceTo(ptr, 0) else null;
    return resolve(ffi.allocator, req);
}

fn isDirectory(path: []const u8) bool {
    var dir = std.fs.openDirAbsolute(path, .{}) catch return false;
    defer dir.close();
    const stat = dir.stat() catch return false;
    return stat.kind == .directory;
}

pub fn standardizeAbsolute(allocator: std.mem.Allocator, path: []const u8, base: []const u8) ![]u8 {
    const expanded = try expandTilde(allocator, path);
    defer allocator.free(expanded);

    const absolute = if (std.fs.path.isAbsolute(expanded))
        try allocator.dupe(u8, expanded)
    else
        try std.fs.path.join(allocator, &.{ base, expanded });
    defer allocator.free(absolute);

    return normalizeLexical(allocator, absolute);
}

fn expandTilde(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path[0] != '~') return allocator.dupe(u8, path);

    const home = std.posix.getenv("HOME") orelse "";
    if (path.len == 1) return allocator.dupe(u8, home);
    if (path[1] == '/') return std.fs.path.join(allocator, &.{ home, path[2..] });

    // Swift NSString.expandingTildeInPath only expands the current user's "~".
    return allocator.dupe(u8, path);
}

fn normalizeLexical(allocator: std.mem.Allocator, absolute: []const u8) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    var it = std.mem.splitScalar(u8, absolute, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(allocator, part);
    }

    if (parts.items.len == 0) return allocator.dupe(u8, "/");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.append(allocator, '/');
    for (parts.items, 0..) |part, i| {
        if (i != 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, part);
    }
    return out.toOwnedSlice(allocator);
}

test "standardize absolute resolves dot segments" {
    const got = try standardizeAbsolute(std.testing.allocator, "../tmp/./x", "/Users/example/project");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("/Users/example/tmp/x", got);
}
