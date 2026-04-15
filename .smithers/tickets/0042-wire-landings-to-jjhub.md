# Wire Landings to Real JJHub Backend

## Problem

The landings view uses stub/mock data and is not connected to the real JJHub
API.

Review: landings.

## Current State

- Landings data is hardcoded or returns empty results outside of UI tests.

## Proposed Changes

- Implement `SmithersClient.listLandings` using the real JJHub CLI or API.
- Decode the response into existing landing models.
- Wire the landings view to fetch on appear and support refresh.

## Files

- `SmithersClient.swift`
- `SmithersModels.swift`
- Landings view files

## Acceptance Criteria

- Landings view shows real data from JJHub.
- Loading, empty, and error states are handled.
