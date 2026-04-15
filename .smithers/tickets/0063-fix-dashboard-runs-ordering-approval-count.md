# Fix Dashboard Runs Ordering and Approval Counting

## Problem

Dashboard runs are not ordered by recency, and the approval count badge
miscounts pending approvals.

Review: dashboard.

## Current State

- Runs may appear in insertion order rather than by start time.
- Approval count does not match the filtered pending approvals list.

## Proposed Changes

- Sort runs by start time descending.
- Compute approval count from the actual filtered pending approvals.

## Files

- Dashboard view files
- `SmithersModels.swift` (if sorting is model-level)

## Acceptance Criteria

- Runs are displayed most-recent-first.
- Approval badge count matches the pending approvals list.
