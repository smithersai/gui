const std = @import("std");
const models = @import("models");

test "parse stub dashboard models" {
    const alloc = std.testing.allocator;

    var workflows = try models.parseWorkflows(alloc,
        \\[{"id":"wf","name":"Workflow","relativePath":".smithers/workflows/wf.tsx","status":"active"}]
    );
    defer {
        models.clearList(models.Workflow, alloc, &workflows);
        workflows.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), workflows.items.len);
    try std.testing.expectEqualStrings("Workflow", workflows.items[0].name);

    var runs = try models.parseRuns(alloc,
        \\[{"runId":"run-1","workflowName":"Workflow","status":"running","summary":{"total":2,"finished":1,"failed":0}}]
    );
    defer {
        models.clearList(models.RunSummary, alloc, &runs);
        runs.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), runs.items.len);
    try std.testing.expectEqual(@as(i64, 2), runs.items[0].total);
}
