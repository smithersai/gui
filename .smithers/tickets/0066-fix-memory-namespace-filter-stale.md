# Fix Namespace Filter State Stale After Refresh

## Problem

After refreshing the memory list, the namespace filter retains the old
selection even if that namespace no longer exists, showing an empty list
with no indication of why.

Review: memory.

## Current State

- Namespace filter is not reset or validated after data refresh.

## Proposed Changes

- After refresh, validate the selected namespace still exists in the new
  data.
- Reset to "all" if the selected namespace is gone.

## Files

- Memory view files

## Acceptance Criteria

- Namespace filter resets to a valid value after refresh.
- Users see results (or a clear empty state) after refresh.
