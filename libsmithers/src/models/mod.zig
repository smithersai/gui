const std = @import("std");
const ffi = @import("../ffi.zig");

pub const app = @import("app.zig");

pub const ModelDescriptor = struct {
    name: []const u8,
    sample_json: []const u8,
};

pub const smithers_model_descriptors = [_]ModelDescriptor{
    .{ .name = "RunStatus", .sample_json = "\"running\"" },
    .{ .name = "RunSummary", .sample_json = "{\"runId\":\"run-1\",\"workflowName\":\"Ship\",\"status\":\"running\"}" },
    .{ .name = "RunTask", .sample_json = "{\"id\":\"task:build\",\"status\":\"running\"}" },
    .{ .name = "RunInspection", .sample_json = "{\"run\":{\"runId\":\"run-1\"},\"tasks\":[]}" },
    .{ .name = "SmithersAgent", .sample_json = "{\"id\":\"codex\",\"name\":\"Codex\"}" },
    .{ .name = "CodexAuthState", .sample_json = "{\"isAuthenticated\":true}" },
    .{ .name = "WorkflowStatus", .sample_json = "\"available\"" },
    .{ .name = "Workflow", .sample_json = "{\"id\":\"workflow:ship\",\"name\":\"Ship\",\"relativePath\":\".smithers/workflows/ship.tsx\"}" },
    .{ .name = "WorkflowLaunchField", .sample_json = "{\"name\":\"target\",\"type\":\"string\"}" },
    .{ .name = "WorkflowDAGXMLNode", .sample_json = "{\"tag\":\"Task\",\"attrs\":{}}" },
    .{ .name = "WorkflowDAGTask", .sample_json = "{\"id\":\"task:build\",\"label\":\"Build\"}" },
    .{ .name = "WorkflowDAGEdge", .sample_json = "{\"id\":\"a->b\",\"source\":\"a\",\"target\":\"b\"}" },
    .{ .name = "WorkflowDAG", .sample_json = "{\"tasks\":[],\"edges\":[]}" },
    .{ .name = "WorkflowDoctorIssue", .sample_json = "{\"id\":\"issue-1\",\"severity\":\"warning\",\"message\":\"Missing description\"}" },
    .{ .name = "Approval", .sample_json = "{\"id\":\"approval-1\",\"runId\":\"run-1\",\"nodeId\":\"task\"}" },
    .{ .name = "ApprovalDecision", .sample_json = "{\"id\":\"decision-1\",\"approved\":true}" },
    .{ .name = "SmithersPrompt", .sample_json = "{\"id\":\"prompt:review\",\"entryFile\":\"review.mdx\"}" },
    .{ .name = "PromptInput", .sample_json = "{\"id\":\"name\",\"name\":\"name\",\"required\":true}" },
    .{ .name = "ScoreRow", .sample_json = "{\"id\":\"score-1\",\"runId\":\"run-1\",\"score\":0.95}" },
    .{ .name = "AggregateScore", .sample_json = "{\"id\":\"scorer\",\"name\":\"scorer\",\"average\":0.9}" },
    .{ .name = "MetricsFilter", .sample_json = "{\"runId\":\"run-1\"}" },
    .{ .name = "TokenMetrics", .sample_json = "{\"totalTokens\":42}" },
    .{ .name = "TokenPeriodBatch", .sample_json = "{\"period\":\"day\",\"items\":[]}" },
    .{ .name = "LatencyMetrics", .sample_json = "{\"p50\":10,\"p95\":20}" },
    .{ .name = "LatencyPeriodBatch", .sample_json = "{\"period\":\"day\",\"items\":[]}" },
    .{ .name = "CostReport", .sample_json = "{\"totalCost\":1.25}" },
    .{ .name = "CostPeriodBatch", .sample_json = "{\"period\":\"day\",\"items\":[]}" },
    .{ .name = "MemoryFact", .sample_json = "{\"id\":\"fact-1\",\"content\":\"Remember this\"}" },
    .{ .name = "MemoryRecallResult", .sample_json = "{\"id\":\"fact-1\",\"score\":0.8}" },
    .{ .name = "TimelineResponse", .sample_json = "{\"timeline\":{\"frames\":[]}}" },
    .{ .name = "Timeline", .sample_json = "{\"branches\":[],\"frames\":[],\"forks\":[]}" },
    .{ .name = "TimelineBranch", .sample_json = "{\"id\":\"main\",\"name\":\"main\"}" },
    .{ .name = "TimelineFrame", .sample_json = "{\"frameNo\":1,\"snapshotId\":\"snap-1\"}" },
    .{ .name = "TimelineFork", .sample_json = "{\"id\":\"fork-1\",\"fromFrame\":1}" },
    .{ .name = "Snapshot", .sample_json = "{\"id\":\"snap-1\",\"runId\":\"run-1\"}" },
    .{ .name = "SnapshotDiff", .sample_json = "{\"fromId\":\"a\",\"toId\":\"b\",\"nodeChanges\":[]}" },
    .{ .name = "SnapshotDiffResponse", .sample_json = "{\"diff\":{\"fromId\":\"a\",\"toId\":\"b\"}}" },
    .{ .name = "SnapshotNodeChange", .sample_json = "{\"nodeId\":\"task\",\"change\":\"modified\"}" },
    .{ .name = "SnapshotNodeState", .sample_json = "{\"nodeId\":\"task\",\"status\":\"running\"}" },
    .{ .name = "SnapshotOutputChange", .sample_json = "{\"nodeId\":\"task\",\"diff\":\"\"}" },
    .{ .name = "SnapshotRalphChange", .sample_json = "{\"id\":\"ralph\",\"change\":\"added\"}" },
    .{ .name = "SnapshotRalphState", .sample_json = "{\"id\":\"ralph\",\"value\":{}}" },
    .{ .name = "JSONValue", .sample_json = "{\"kind\":\"string\",\"value\":\"hello\"}" },
    .{ .name = "CreateTicketInput", .sample_json = "{\"id\":\"T-1\",\"content\":\"Do it\"}" },
    .{ .name = "UpdateTicketInput", .sample_json = "{\"content\":\"Updated\"}" },
    .{ .name = "Ticket", .sample_json = "{\"id\":\"T-1\",\"content\":\"Do it\"}" },
    .{ .name = "Landing", .sample_json = "{\"id\":\"LR-1\",\"title\":\"Land change\"}" },
    .{ .name = "SmithersIssue", .sample_json = "{\"id\":\"ISS-1\",\"title\":\"Fix bug\"}" },
    .{ .name = "Workspace", .sample_json = "{\"id\":\"ws-1\",\"path\":\"/tmp/repo\"}" },
    .{ .name = "WorkspaceSnapshot", .sample_json = "{\"id\":\"wss-1\",\"workspaceId\":\"ws-1\"}" },
    .{ .name = "JJHubWorkflow", .sample_json = "{\"id\":1,\"name\":\"CI\"}" },
    .{ .name = "JJHubWorkflowRun", .sample_json = "{\"id\":1,\"status\":\"queued\"}" },
    .{ .name = "JJHubRepo", .sample_json = "{\"name\":\"repo\",\"owner\":\"org\"}" },
    .{ .name = "JJHubAuthor", .sample_json = "{\"name\":\"Ada\",\"email\":\"ada@example.com\"}" },
    .{ .name = "JJHubChange", .sample_json = "{\"id\":\"abc\",\"description\":\"change\"}" },
    .{ .name = "JJHubBookmark", .sample_json = "{\"id\":\"main\",\"name\":\"main\"}" },
    .{ .name = "ChatBlock", .sample_json = "{\"id\":\"block-1\",\"role\":\"assistant\",\"content\":\"hi\"}" },
    .{ .name = "HijackLaunchInvocation", .sample_json = "{\"command\":\"smithers hijack run-1\"}" },
    .{ .name = "HijackSession", .sample_json = "{\"id\":\"hijack-1\",\"runId\":\"run-1\"}" },
    .{ .name = "CronSchedule", .sample_json = "{\"id\":\"cron-1\",\"name\":\"Nightly\"}" },
    .{ .name = "CronResponse", .sample_json = "{\"schedules\":[]}" },
    .{ .name = "SQLTableInfo", .sample_json = "{\"name\":\"runs\",\"type\":\"table\"}" },
    .{ .name = "SQLTableColumn", .sample_json = "{\"name\":\"id\",\"type\":\"TEXT\"}" },
    .{ .name = "SQLTableSchema", .sample_json = "{\"table\":\"runs\",\"columns\":[]}" },
    .{ .name = "SQLResult", .sample_json = "{\"columns\":[\"id\"],\"rows\":[[\"run-1\"]]}" },
    .{ .name = "SQLCellValue", .sample_json = "\"run-1\"" },
    .{ .name = "SearchScope", .sample_json = "\"all\"" },
    .{ .name = "SearchSnippetRange", .sample_json = "{\"start\":0,\"end\":5}" },
    .{ .name = "SearchResult", .sample_json = "{\"id\":\"result-1\",\"title\":\"Match\"}" },
    .{ .name = "SSEEvent", .sample_json = "{\"event\":\"message\",\"data\":\"{}\"}" },
    .{ .name = "APIEnvelope", .sample_json = "{\"data\":{},\"error\":null}" },
};

pub fn descriptorByName(name: []const u8) ?ModelDescriptor {
    for (smithers_model_descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.name, name)) return descriptor;
    }
    for (app.app_model_descriptors) |descriptor| {
        if (std.mem.eql(u8, descriptor.name, name)) return descriptor;
    }
    return null;
}

pub fn roundTripJson(allocator: std.mem.Allocator, model_name: []const u8, input: []const u8) ![]u8 {
    _ = descriptorByName(model_name) orelse return error.UnknownModel;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn validateJson(model_name: []const u8, input: []const u8) bool {
    const out = roundTripJson(ffi.allocator, model_name, input) catch return false;
    ffi.allocator.free(out);
    return true;
}

test "all model samples round trip as JSON" {
    for (smithers_model_descriptors) |descriptor| {
        const out = try roundTripJson(std.testing.allocator, descriptor.name, descriptor.sample_json);
        defer std.testing.allocator.free(out);
        try std.testing.expect(out.len > 0);
    }
}
