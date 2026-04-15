# Fix CronSchedule Empty ID Decoding

## Problem

`CronSchedule` decoding fails or produces an empty ID when the CLI returns
a cron entry without an explicit `id` field.

Review: models.

## Current State

- The `id` field is required in the model but may be absent in CLI output.

## Proposed Changes

- Make `id` optional or generate a deterministic fallback from the schedule
  expression and workflow path.

## Files

- `SmithersModels.swift`

## Acceptance Criteria

- Cron schedules without an explicit ID decode successfully.
- Fallback IDs are stable and unique.
