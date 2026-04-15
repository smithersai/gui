# Wire Search to Real Backend

## Problem

The search view uses stub/mock data and is not connected to the real backend.

Review: search.

## Current State

- Search results are hardcoded or returns empty results outside of UI tests.

## Proposed Changes

- Implement `SmithersClient.search` using the real CLI or API.
- Decode the response into existing search result models.
- Wire the search view to execute queries against the backend.

## Files

- `SmithersClient.swift`
- `SmithersModels.swift`
- Search view files

## Acceptance Criteria

- Search returns real results from the backend.
- Loading, empty, and error states are handled.
