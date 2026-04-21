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

test "parse nested envelopes and approval iterations" {
    const alloc = std.testing.allocator;

    var workflows = try models.parseWorkflows(alloc,
        \\{"data":{"items":[{"id":"wf-nested","name":"Nested","status":"active"}]}}
    );
    defer {
        models.clearList(models.Workflow, alloc, &workflows);
        workflows.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), workflows.items.len);
    try std.testing.expectEqualStrings("wf-nested", workflows.items[0].id);

    var approvals = try models.parseApprovals(alloc,
        \\{"approvals":{"items":[{"id":"a1","runId":"r1","nodeId":"gate","status":"pending","iteration":2}]}}
    );
    defer {
        models.clearList(models.Approval, alloc, &approvals);
        approvals.deinit(alloc);
    }
    try std.testing.expectEqual(@as(usize, 1), approvals.items.len);
    try std.testing.expectEqual(@as(?i64, 2), approvals.items[0].iteration);

    var inspection = try models.parseRunInspection(alloc,
        \\{"run":{"runId":"r1","status":"running"},"tasks":{"items":[{"nodeId":"n1","status":"waiting"}]}}
    );
    defer inspection.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), inspection.tasks.items.len);
    try std.testing.expectEqualStrings("n1", inspection.tasks.items[0].node_id);

    var workspaces = try models.parseWorkspaces(alloc,
        \\[{"id":"cloud-id","path":"/tmp/smithers","name":"Smithers"}]
    );
    defer {
        models.clearList(models.Workspace, alloc, &workspaces);
        workspaces.deinit(alloc);
    }
    try std.testing.expectEqualStrings("/tmp/smithers", workspaces.items[0].id);
}
