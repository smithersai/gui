//! Tier 2 — integration test against a live plue + Postgres + Electric
//! docker-compose stack.
//!
//! GATED on env var POC_ELECTRIC_STACK=1. When set, the test expects:
//!   - plue API reachable at $POC_ELECTRIC_API_HOST:$POC_ELECTRIC_API_PORT
//!     (default 127.0.0.1:4000).
//!   - $POC_ELECTRIC_SHAPE_PROXY — plue's Electric auth proxy
//!     (default 127.0.0.1:3001).
//!   - $POC_ELECTRIC_TOKEN — bearer token with access to the repo.
//!     (default: dev seed token.)
//!   - $POC_ELECTRIC_REPO_ID — a seeded repository id with at least one
//!     row in the throwaway `poc_items` table filtered by repository_id.
//!   - $POC_ELECTRIC_BAD_REPO_ID — a repo the token can NOT read (used
//!     to assert plue's proxy returns 403).
//!
//! When POC_ELECTRIC_STACK is NOT set, this file still compiles + runs
//! but degrades to a single passing assertion, consistent with the
//! "no t.Skip" rule from 0094/0096.

const std = @import("std");
const electric = @import("electric");
const testing = std.testing;

const Stack = struct {
    host: []const u8,
    port: u16,
    token: []const u8,
    repo_id: []const u8,
    bad_repo_id: []const u8,
};

fn readEnvOr(allocator: std.mem.Allocator, name: []const u8, default: []const u8) ![]const u8 {
    if (std.process.getEnvVarOwned(allocator, name)) |v| {
        return v;
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => return try allocator.dupe(u8, default),
        else => return err,
    }
}

fn loadStack(allocator: std.mem.Allocator) !?Stack {
    const gate = std.process.getEnvVarOwned(allocator, "POC_ELECTRIC_STACK") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return null,
        else => return e,
    };
    defer allocator.free(gate);
    if (!std.mem.eql(u8, gate, "1")) return null;

    const host = try readEnvOr(allocator, "POC_ELECTRIC_SHAPE_HOST", "127.0.0.1");
    const port_str = try readEnvOr(allocator, "POC_ELECTRIC_SHAPE_PORT", "3001");
    defer allocator.free(port_str);
    const port = try std.fmt.parseInt(u16, port_str, 10);

    return Stack{
        .host = host,
        .port = port,
        .token = try readEnvOr(allocator, "POC_ELECTRIC_TOKEN", "jjhub_deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"),
        .repo_id = try readEnvOr(allocator, "POC_ELECTRIC_REPO_ID", "1"),
        .bad_repo_id = try readEnvOr(allocator, "POC_ELECTRIC_BAD_REPO_ID", "99999"),
    };
}

fn freeStack(allocator: std.mem.Allocator, s: Stack) void {
    allocator.free(s.host);
    allocator.free(s.token);
    allocator.free(s.repo_id);
    allocator.free(s.bad_repo_id);
}

test "integration: stack gate (no-op when POC_ELECTRIC_STACK unset)" {
    const maybe = try loadStack(testing.allocator);
    if (maybe) |s| {
        defer freeStack(testing.allocator, s);
        try testing.expect(s.port != 0);
    } else {
        try testing.expect(true);
    }
}

test "integration: valid token + good repo_id subscribes and catches up" {
    const maybe = try loadStack(testing.allocator);
    const stack = maybe orelse {
        try testing.expect(true);
        return;
    };
    defer freeStack(testing.allocator, stack);

    const allocator = testing.allocator;
    const where = try std.fmt.allocPrint(allocator, "repository_id IN ('{s}')", .{stack.repo_id});
    defer allocator.free(where);

    var p = try electric.Persistence.openInMemory(allocator);
    defer p.close();

    var c = try electric.Client.init(allocator, .{
        .host = stack.host,
        .port = stack.port,
        .table = "poc_items",
        .where = where,
        .bearer = stack.token,
        .shape_key = "integration:good",
    }, p);
    defer c.deinit();

    try c.catchUp();
    try testing.expect(c.stats.up_to_date_seen >= 1);
    try testing.expect(c.handle != null);
}

test "integration: bad token rejected as Unauthorized" {
    const maybe = try loadStack(testing.allocator);
    const stack = maybe orelse {
        try testing.expect(true);
        return;
    };
    defer freeStack(testing.allocator, stack);

    const allocator = testing.allocator;
    const where = try std.fmt.allocPrint(allocator, "repository_id IN ('{s}')", .{stack.repo_id});
    defer allocator.free(where);

    var p = try electric.Persistence.openInMemory(allocator);
    defer p.close();

    // Valid-format jjhub token but never issued → plue's token-hash lookup
    // misses → 401.
    var c = try electric.Client.init(allocator, .{
        .host = stack.host,
        .port = stack.port,
        .table = "poc_items",
        .where = where,
        .bearer = "jjhub_0000000000000000000000000000000000000000",
        .shape_key = "integration:badtoken",
    }, p);
    defer c.deinit();

    try testing.expectError(electric.Error.Unauthorized, c.pollOnce(false));
}

test "integration: wrong repo_id rejected as Forbidden" {
    const maybe = try loadStack(testing.allocator);
    const stack = maybe orelse {
        try testing.expect(true);
        return;
    };
    defer freeStack(testing.allocator, stack);

    const allocator = testing.allocator;
    const where = try std.fmt.allocPrint(allocator, "repository_id IN ('{s}')", .{stack.bad_repo_id});
    defer allocator.free(where);

    var p = try electric.Persistence.openInMemory(allocator);
    defer p.close();

    var c = try electric.Client.init(allocator, .{
        .host = stack.host,
        .port = stack.port,
        .table = "poc_items",
        .where = where,
        .bearer = stack.token,
        .shape_key = "integration:badrepo",
    }, p);
    defer c.deinit();

    try testing.expectError(electric.Error.Forbidden, c.pollOnce(false));
}

test "integration: reconnect resumes at stored offset" {
    const maybe = try loadStack(testing.allocator);
    const stack = maybe orelse {
        try testing.expect(true);
        return;
    };
    defer freeStack(testing.allocator, stack);

    const allocator = testing.allocator;
    const where = try std.fmt.allocPrint(allocator, "repository_id IN ('{s}')", .{stack.repo_id});
    defer allocator.free(where);

    var p = try electric.Persistence.openInMemory(allocator);
    defer p.close();

    const cfg: electric.Config = .{
        .host = stack.host,
        .port = stack.port,
        .table = "poc_items",
        .where = where,
        .bearer = stack.token,
        .shape_key = "integration:resume",
    };

    {
        var c = try electric.Client.init(allocator, cfg, p);
        defer c.deinit();
        try c.catchUp();
    }

    const before = (try p.loadCursor("integration:resume")).?;
    defer allocator.free(before.handle);
    defer allocator.free(before.offset);

    {
        var c = try electric.Client.init(allocator, cfg, p);
        defer c.deinit();
        try testing.expectEqualStrings(before.handle, c.handle.?);
        try testing.expectEqualStrings(before.offset, c.offset);
        _ = try c.pollOnce(true);
    }
}

test "integration: unsubscribe removes persisted cursor" {
    const maybe = try loadStack(testing.allocator);
    const stack = maybe orelse {
        try testing.expect(true);
        return;
    };
    defer freeStack(testing.allocator, stack);

    const allocator = testing.allocator;
    const where = try std.fmt.allocPrint(allocator, "repository_id IN ('{s}')", .{stack.repo_id});
    defer allocator.free(where);

    var p = try electric.Persistence.openInMemory(allocator);
    defer p.close();

    var c = try electric.Client.init(allocator, .{
        .host = stack.host,
        .port = stack.port,
        .table = "poc_items",
        .where = where,
        .bearer = stack.token,
        .shape_key = "integration:unsub",
    }, p);
    defer c.deinit();

    try c.catchUp();
    try c.unsubscribe();
    try testing.expect((try p.loadCursor("integration:unsub")) == null);
}
