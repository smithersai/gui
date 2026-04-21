const std = @import("std");
const zbench = @import("zbench");
const common = @import("common.zig");

// Measures the JSON serde path used for model transport across the narrow C
// ABI. The model layer validates the model name, parses std.json.Value, then
// stringifies it back out for representative Smithers payload sizes.

const narrative =
    "JSON serde round-trips representative RunSummary, Workflow, ChatBlock, Ticket, and SearchResult payloads through libsmithers model descriptors.";

const run_summary_json =
    \\{"runId":"run-2026-04-21-0001","workflowName":"Ship GUI","status":"running","workspacePath":"/Users/williamcory/gui","startedAt":"2026-04-21T10:15:30Z","currentNode":"task:test","agents":[{"id":"codex","name":"Codex","status":"working"}],"cost":{"usd":0.42,"tokens":12345}}
;

const workflow_json =
    \\{"id":"workflow:ship-gui","name":"Ship GUI","relativePath":".smithers/workflows/ship-gui.tsx","status":"available","description":"Build, test, and land the Smithers GUI app.","launchFields":[{"name":"target","type":"string","required":true},{"name":"dryRun","type":"boolean","required":false}],"dag":{"tasks":[{"id":"task:build","label":"Build"},{"id":"task:test","label":"Test"},{"id":"task:land","label":"Land"}],"edges":[{"id":"build-test","source":"task:build","target":"task:test"},{"id":"test-land","source":"task:test","target":"task:land"}]}}
;

const chat_block_json =
    \\{"id":"block-1","role":"assistant","createdAt":"2026-04-21T10:15:35Z","content":"The benchmark suite now covers cwd resolution, slash parsing, palette scoring, client calls, event stream draining, persistence round trips, model JSON serde, action conversion, and lifecycle setup. This payload intentionally carries enough text to resemble a normal assistant chat block rather than a tiny fixture.","toolCalls":[{"id":"tool-1","name":"zig build","status":"completed","output":"Build completed successfully."}],"metadata":{"runId":"run-1","sessionId":"session-1","tokens":384}}
;

const ticket_json =
    \\{"id":"T-123","title":"Benchmark palette query performance","content":"Add zbench coverage for command palette scoring with large synthetic backing stores so regressions are visible before UI latency changes.","status":"open","priority":"high","labels":["bench","libsmithers","gui"],"assignee":{"name":"Bench Agent E6","email":"bench@example.com"},"createdAt":"2026-04-21T10:16:00Z","updatedAt":"2026-04-21T10:20:00Z","links":[{"title":"contract","url":"docs/libsmithers-contract.md"}]}
;

const search_result_json =
    \\{"id":"result-1","title":"libsmithers benchmark request","kind":"code","path":"libsmithers/bench/src/main.zig","score":0.982,"snippets":[{"line":42,"text":"smithers_palette_set_query plus smithers_palette_items_json","ranges":[{"start":0,"end":52}]},{"line":87,"text":"smithers_event_stream_next drains fixture streams","ranges":[{"start":0,"end":43}]}],"repository":{"name":"gui","owner":"williamcory"},"metadata":{"query":"palette stream persistence","elapsedMs":12.4,"totalResults":18}}
;

pub fn add(bench: *zbench.Benchmark, registry: *common.Registry) !void {
    try addCase(bench, registry, "json.RunSummary", "RunSummary", run_summary_json, benchRunSummary);
    try addCase(bench, registry, "json.Workflow", "Workflow", workflow_json, benchWorkflow);
    try addCase(bench, registry, "json.ChatBlock", "ChatBlock", chat_block_json, benchChatBlock);
    try addCase(bench, registry, "json.Ticket", "Ticket", ticket_json, benchTicket);
    try addCase(bench, registry, "json.SearchResult", "SearchResult", search_result_json, benchSearchResult);
}

fn addCase(
    bench: *zbench.Benchmark,
    registry: *common.Registry,
    name: []const u8,
    comptime _: []const u8,
    payload: []const u8,
    func: zbench.BenchFunc,
) !void {
    try registry.addSimple(bench, .{
        .name = name,
        .group = "json",
        .narrative = narrative,
        .units_per_run = @floatFromInt(payload.len),
        .unit = "bytes",
    }, func, common.default_config);
}

fn roundTrip(comptime model_name: []const u8, payload: []const u8, allocator: std.mem.Allocator) void {
    var arena = common.freshArena(allocator);
    defer arena.deinit();
    const out = roundTripJson(arena.allocator(), model_name, payload) catch @panic("json round trip failed");
    common.consumeBytes(out);
}

fn roundTripJson(allocator: std.mem.Allocator, model_name: []const u8, input: []const u8) ![]u8 {
    if (!knownModel(model_name)) return error.UnknownModel;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, input, .{});
    defer parsed.deinit();
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try std.json.Stringify.value(parsed.value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn knownModel(model_name: []const u8) bool {
    const names = [_][]const u8{ "RunSummary", "Workflow", "ChatBlock", "Ticket", "SearchResult" };
    for (names) |name| {
        if (std.mem.eql(u8, model_name, name)) return true;
    }
    return false;
}

fn benchRunSummary(allocator: std.mem.Allocator) void {
    roundTrip("RunSummary", run_summary_json, allocator);
}

fn benchWorkflow(allocator: std.mem.Allocator) void {
    roundTrip("Workflow", workflow_json, allocator);
}

fn benchChatBlock(allocator: std.mem.Allocator) void {
    roundTrip("ChatBlock", chat_block_json, allocator);
}

fn benchTicket(allocator: std.mem.Allocator) void {
    roundTrip("Ticket", ticket_json, allocator);
}

fn benchSearchResult(allocator: std.mem.Allocator) void {
    roundTrip("SearchResult", search_result_json, allocator);
}
