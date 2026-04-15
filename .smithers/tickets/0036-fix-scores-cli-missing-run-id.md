# Fix Scores CLI Missing Required runId

## Problem

`SmithersClient` calls `smithers scores` without the required `runId`
argument, so the command fails against the real CLI.

Reviews: scores, transport.

## Current State

- Scores list/fetch commands omit the positional run ID.
- The CLI requires `smithers scores <runId>`.

## Proposed Changes

- Pass `runId` as a positional argument to the scores CLI command.
- Ensure the scores view provides the active run ID when fetching.

## Files

- `SmithersClient.swift`
- Scores-related views

## Acceptance Criteria

- `smithers scores` is invoked with a valid run ID.
- Score data loads correctly for the selected run.
