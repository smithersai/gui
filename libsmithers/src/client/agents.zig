const std = @import("std");

pub const EnvLookup = *const fn ([]const u8) ?[]const u8;

pub const Manifest = struct {
    id: []const u8,
    name: []const u8,
    command: []const u8,
    roles: []const []const u8,
    auth_dir: ?[]const u8,
    api_key_env: ?[]const u8,
};

pub const known_agents = [_]Manifest{
    .{
        .id = "claude-code",
        .name = "Claude Code",
        .command = "claude",
        .roles = &.{ "coding", "review", "spec" },
        .auth_dir = ".claude",
        .api_key_env = "ANTHROPIC_API_KEY",
    },
    .{
        .id = "codex",
        .name = "Codex",
        .command = "codex",
        .roles = &.{ "coding", "implement" },
        .auth_dir = ".codex",
        .api_key_env = "OPENAI_API_KEY",
    },
    .{
        .id = "opencode",
        .name = "OpenCode",
        .command = "opencode",
        .roles = &.{ "coding", "chat" },
        .auth_dir = null,
        .api_key_env = null,
    },
    .{
        .id = "gemini",
        .name = "Gemini",
        .command = "gemini",
        .roles = &.{ "coding", "research" },
        .auth_dir = ".gemini",
        .api_key_env = "GEMINI_API_KEY",
    },
    .{
        .id = "kimi",
        .name = "Kimi",
        .command = "kimi",
        .roles = &.{ "research", "plan" },
        .auth_dir = null,
        .api_key_env = "KIMI_API_KEY",
    },
    .{
        .id = "amp",
        .name = "Amp",
        .command = "amp",
        .roles = &.{ "coding", "validate" },
        .auth_dir = ".amp",
        .api_key_env = null,
    },
    .{
        .id = "forge",
        .name = "Forge",
        .command = "forge",
        .roles = &.{"coding"},
        .auth_dir = null,
        .api_key_env = "FORGE_API_KEY",
    },
};

pub fn processEnvLookup(name: []const u8) ?[]const u8 {
    return std.posix.getenv(name);
}

pub fn nullEnvLookup(_: []const u8) ?[]const u8 {
    return null;
}

pub fn detect(
    allocator: std.mem.Allocator,
    path_env: ?[]const u8,
    home_dir: ?[]const u8,
    env_lookup: EnvLookup,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try out.writer.writeAll("{\"agents\":[");

    for (known_agents, 0..) |agent, index| {
        const binary_path = try resolveBinaryPath(allocator, path_env, agent.command);
        defer if (binary_path) |p| allocator.free(p);

        const has_auth = try hasAuthDir(allocator, home_dir, agent.auth_dir);
        const has_api_key = hasApiKey(env_lookup, agent.api_key_env);
        const usable = binary_path != null;
        const status = classify(has_auth, has_api_key, usable);

        if (index > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(.{
            .id = agent.id,
            .name = agent.name,
            .command = agent.command,
            .binaryPath = if (binary_path) |p| p else "",
            .status = status,
            .hasAuth = has_auth,
            .hasAPIKey = has_api_key,
            .usable = usable,
            .roles = agent.roles,
            .version = @as(?[]const u8, null),
            .authExpired = @as(?bool, null),
        }, .{}, &out.writer);
    }

    try out.writer.writeAll("]}");
    return out.toOwnedSlice();
}

pub fn classify(has_auth: bool, has_api_key: bool, usable: bool) []const u8 {
    if (!usable) return "unavailable";
    if (has_auth) return "likely-subscription";
    if (has_api_key) return "api-key";
    return "binary-only";
}

pub fn resolveBinaryPath(
    allocator: std.mem.Allocator,
    path_env: ?[]const u8,
    command: []const u8,
) !?[]u8 {
    const path = path_env orelse return null;
    if (path.len == 0) return null;

    var iter = std.mem.splitScalar(u8, path, ':');
    while (iter.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = try std.fs.path.join(allocator, &.{ dir, command });
        if (isExecutable(candidate)) return candidate;
        allocator.free(candidate);
    }
    return null;
}

fn isExecutable(path: []const u8) bool {
    std.posix.access(path, std.posix.X_OK) catch return false;
    return true;
}

fn hasAuthDir(allocator: std.mem.Allocator, home_dir: ?[]const u8, auth_dir: ?[]const u8) !bool {
    const home = home_dir orelse return false;
    const dir = auth_dir orelse return false;
    if (home.len == 0) return false;

    const joined = std.fs.path.join(allocator, &.{ home, dir }) catch return false;
    defer allocator.free(joined);

    var opened = std.fs.openDirAbsolute(joined, .{}) catch return false;
    defer opened.close();
    const stat = opened.stat() catch return false;
    return stat.kind == .directory;
}

fn hasApiKey(env_lookup: EnvLookup, api_key_env: ?[]const u8) bool {
    const key = api_key_env orelse return false;
    const value = env_lookup(key) orelse return false;
    return value.len > 0;
}

test "classify precedence" {
    try std.testing.expectEqualStrings("unavailable", classify(true, true, false));
    try std.testing.expectEqualStrings("likely-subscription", classify(true, false, true));
    try std.testing.expectEqualStrings("likely-subscription", classify(true, true, true));
    try std.testing.expectEqualStrings("api-key", classify(false, true, true));
    try std.testing.expectEqualStrings("binary-only", classify(false, false, true));
}
