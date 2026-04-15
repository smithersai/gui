# Wire Issues to Real JJHub Backend

## Problem

The issues view uses stub/mock data and is not connected to the real JJHub
API.

Review: issues.

## Current State

- Issues data is hardcoded or returns empty results outside of UI tests.

## Proposed Changes

- Implement `SmithersClient.listIssues` using the real JJHub CLI or API.
- Decode the response into existing issue models.
- Wire the issues view to fetch on appear and support refresh.

## Files

- `SmithersClient.swift`
- `SmithersModels.swift`
- Issues view files

## Acceptance Criteria

- Issues view shows real data from JJHub.
- Loading, empty, and error states are handled.
