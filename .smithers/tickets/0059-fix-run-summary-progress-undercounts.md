# Fix RunSummary.progress Undercounts Failed Nodes

## Problem

`RunSummary.progress` calculation does not count failed nodes as completed
work, causing the progress bar to undercount.

Review: models.

## Current State

- Progress is computed as `succeeded / total`, ignoring failed nodes.

## Proposed Changes

- Include failed nodes in the completed count: `(succeeded + failed) / total`.
- Display failed vs succeeded distinctly in the progress indicator.

## Files

- `SmithersModels.swift`

## Acceptance Criteria

- Progress reflects all completed nodes (succeeded + failed).
- Failed nodes are visually distinguished from succeeded.
