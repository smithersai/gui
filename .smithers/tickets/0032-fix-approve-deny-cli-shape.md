# Fix Approve/Deny CLI Argument Shape

## Problem

`SmithersClient.approveNode` and `denyNode` build the wrong CLI arguments.
They produce `["approve", "--run", runId, nodeId]` but the real Smithers CLI
expects `smithers approve <runId> --node <nodeId>`. The same mismatch exists
for deny. The `iteration` parameter is accepted but never forwarded.

Reviews: approvals, transport, runs.

## Current State

- `SmithersClient.swift:563` builds approve with `--run` flag + positional nodeId.
- `SmithersClient.swift:578` builds deny the same way.
- `ApprovalsView.swift:216-246` wires buttons to these broken methods.
- UI tests pass only because `UITestSupport` short-circuits the client.

## Proposed Changes

- Change `approveNode` to emit `["approve", runId, "--node", nodeId]`.
- Change `denyNode` to emit `["deny", runId, "--node", nodeId]`.
- Forward `iteration` as `--iteration` when non-nil.
- Update unit tests to assert the corrected argument shape.

## Files

- `SmithersClient.swift`
- `ApprovalsView.swift`

## Acceptance Criteria

- `approveNode` and `denyNode` produce the positional-runId + `--node` shape.
- Iteration is forwarded when provided.
- Existing UI tests still pass; new tests cover the corrected shape.
