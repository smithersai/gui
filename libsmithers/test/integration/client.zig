const std = @import("std");
const h = @import("helpers.zig");

const GoldenCase = struct {
    method: [:0]const u8,
    expected: []const u8,
};

test "client call golden mock responses round-trip unchanged for common methods" {
    const cases = [_]GoldenCase{
        .{
            .method = "listWorkflows",
            .expected = "[{\"name\":\"ship\",\"path\":\".smithers/workflows/ship.tsx\",\"description\":\"Deploy\"}]",
        },
        .{
            .method = "inspectRun",
            .expected = "{\"run\":{\"id\":\"run-1\",\"status\":\"running\"},\"tasks\":[{\"id\":\"task-1\",\"state\":\"done\"}]}",
        },
        .{
            .method = "listRuns",
            .expected = "[{\"runId\":\"run-1\",\"status\":\"active\"},{\"runId\":\"run-2\",\"status\":\"paused\"}]",
        },
        .{
            .method = "listTickets",
            .expected = "[{\"id\":\"T-1\",\"title\":\"Fix flaky scorer\",\"labels\":[\"bug\"]}]",
        },
        .{
            .method = "listMemoryFacts",
            .expected = "[{\"key\":\"repo.language\",\"value\":\"zig\",\"confidence\":0.95}]",
        },
        .{
            .method = "listPrompts",
            .expected = "[{\"id\":\"prompt-1\",\"name\":\"Review\",\"body\":\"Find regressions\"}]",
        },
        .{
            .method = "listAgents",
            .expected = "[{\"id\":\"agent-1\",\"name\":\"Builder\",\"model\":\"gpt-5\"}]",
        },
        .{
            .method = "codexAuthState",
            .expected = "{\"authenticated\":true,\"account\":\"test@example.com\",\"expiresAt\":null}",
        },
        .{
            .method = "listSnapshots",
            .expected = "[{\"id\":\"snap-1\",\"checkpoint\":\"abc123\",\"createdAt\":\"2026-04-21T00:00:00Z\"}]",
        },
        .{
            .method = "getCurrentRepo",
            .expected = "{\"name\":\"smithers-gui\",\"owner\":null,\"root\":\"/tmp/repo\"}",
        },
    };

    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    for (cases) |case| {
        const args_plain = try std.fmt.allocPrint(std.testing.allocator, "{{\"mockResult\":{s}}}", .{case.expected});
        defer std.testing.allocator.free(args_plain);
        const args = try h.dupeZ(args_plain);
        defer std.testing.allocator.free(args);

        var err: h.structs.Error = undefined;
        const result = h.embedded.smithers_client_call(client, case.method, args.ptr, &err);
        defer h.embedded.smithers_string_free(result);
        defer h.embedded.smithers_error_free(err);
        try h.expectSuccess(err);
        try std.testing.expectEqualStrings(case.expected, h.stringSlice(result));
        try h.expectJsonValid(h.stringSlice(result));
    }
}

test "client call supports raw result_json fixture without method-specific defaults" {
    const expected = "{\"ok\":true,\"nested\":{\"empty\":[],\"unknown\":\"forward-compatible\"}}";
    const args_plain = try std.fmt.allocPrint(std.testing.allocator, "{{\"result_json\":{f}}}", .{std.json.fmt(expected, .{})});
    defer std.testing.allocator.free(args_plain);
    const args = try h.dupeZ(args_plain);
    defer std.testing.allocator.free(args);

    const app = h.embedded.smithers_app_new(null).?;
    defer h.embedded.smithers_app_free(app);
    const client = h.embedded.smithers_client_new(app).?;
    defer h.embedded.smithers_client_free(client);

    var err: h.structs.Error = undefined;
    const result = h.embedded.smithers_client_call(client, "unlistedFutureMethod", args.ptr, &err);
    defer h.embedded.smithers_string_free(result);
    defer h.embedded.smithers_error_free(err);
    try h.expectSuccess(err);
    try std.testing.expectEqualStrings(expected, h.stringSlice(result));
}
