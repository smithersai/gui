# Wire Workspaces to Real Backend

## Problem

The workspaces view uses stub/mock data and is not connected to the real
backend.

Review: workspaces.

## Current State

- Workspace data is hardcoded or returns empty results outside of UI tests.

## Proposed Changes

- Implement `SmithersClient.listWorkspaces` using the real CLI or API.
- Decode the response into existing workspace models.
- Wire the workspaces view to fetch on appear and support refresh.

## Files

- `SmithersClient.swift`
- `SmithersModels.swift`
- Workspaces view files

## Acceptance Criteria

- Workspaces view shows real data from the backend.
- Loading, empty, and error states are handled.
