# Fix Scores Aggregate Stats Not Per-Scorer

## Problem

Score aggregates (mean, min, max) are computed across all scorers instead of
per-scorer, making the statistics meaningless when multiple scorers exist.

Review: scores.

## Current State

- All score values are combined into a single aggregate.

## Proposed Changes

- Group scores by scorer name before computing aggregates.
- Display per-scorer statistics in the scores view.

## Files

- Scores view files
- `SmithersModels.swift`

## Acceptance Criteria

- Aggregate statistics are computed and displayed per scorer.
- Multiple scorers are visually separated.
