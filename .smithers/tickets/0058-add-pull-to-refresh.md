# Add Pull-to-Refresh Support

## Problem

List views do not support pull-to-refresh, requiring users to navigate away
and back to reload data.

Review: platform.

## Current State

- No `.refreshable` modifier on list views.

## Proposed Changes

- Add `.refreshable` to key list views (runs, approvals, workflows,
  memories, scores, etc.).
- Wire the refresh action to re-fetch data from the backend.

## Files

- All major list view files

## Acceptance Criteria

- Users can pull to refresh on list views.
- Data reloads correctly on refresh.
