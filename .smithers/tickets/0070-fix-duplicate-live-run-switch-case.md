# Fix Duplicate .liveRun Switch Case

## Problem

There is a duplicate `.liveRun` case in a switch statement, which may cause
the second case to be unreachable or produce unexpected behavior.

Review: ui_build_theme.

## Current State

- Two `case .liveRun` entries exist in the same switch.

## Proposed Changes

- Remove or merge the duplicate case.
- Verify the intended behavior for `.liveRun` routing.

## Files

- `ContentView.swift` or router file containing the switch

## Acceptance Criteria

- No duplicate switch cases.
- `.liveRun` routes to the correct view.
