# Fix Cron List JSON Shape Mismatch

## Problem

`SmithersClient` decodes `smithers cron list` output using a model that does
not match the actual CLI JSON shape.

Review: transport.

## Current State

- Field names or nesting in the cron list response do not match the Swift
  `CronSchedule` model.

## Proposed Changes

- Audit `smithers cron list --json` output against `CronSchedule` model.
- Fix field mappings and optional/required annotations.

## Files

- `SmithersClient.swift`
- `SmithersModels.swift`

## Acceptance Criteria

- Cron list JSON decodes without errors against real CLI output.
- Cron schedules display correctly in the UI.
