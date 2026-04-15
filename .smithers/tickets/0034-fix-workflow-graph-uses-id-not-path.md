# Fix Workflow Graph/Up Uses ID Instead of Path

## Problem

The GUI passes a workflow ID where the CLI expects a file path for
`smithers workflow graph` and `smithers workflow up`. This causes workflow
launch and graph visualization to fail against real Smithers.

Reviews: transport, workflows.

## Current State

- `SmithersClient` sends the workflow's string ID to `graph` and `up` commands.
- The CLI expects a path to the workflow YAML file.

## Proposed Changes

- Store or resolve the workflow file path alongside the workflow ID.
- Pass the file path to `smithers workflow graph` and `smithers workflow up`.
- Update models if needed to carry the path.

## Files

- `SmithersClient.swift`
- `SmithersModels.swift`
- `WorkflowsView.swift` (or equivalent workflow UI)

## Acceptance Criteria

- `workflow graph` and `workflow up` receive a file path, not an ID.
- Workflow launch and graph rendering work against real Smithers CLI.
