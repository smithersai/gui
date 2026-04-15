# Make Timeline/Snapshots UI Reachable from App

## Problem

Timeline and snapshot views exist in the codebase but are not reachable from
any navigation path in the app.

Review: ui_build_theme.

## Current State

- Views are implemented but no sidebar item, menu, or navigation link
  points to them.

## Proposed Changes

- Add timeline/snapshots entry to the sidebar or appropriate navigation.
- Wire the route so users can access the feature.

## Files

- `SidebarView.swift`
- `ContentView.swift`
- Router/navigation files

## Acceptance Criteria

- Users can navigate to the timeline/snapshots view from the app UI.
- The view loads and displays data correctly.
