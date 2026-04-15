# Fix Recall Top-K Not Exposed in GUI

## Problem

The memory recall API supports a `top-k` parameter to limit results, but
the GUI does not expose this control.

Review: memory.

## Current State

- Recall always uses the default `k` value.

## Proposed Changes

- Add a top-K input/slider to the memory recall UI.
- Forward the value to the `smithers memory recall` command.

## Files

- Memory view files
- `SmithersClient.swift`

## Acceptance Criteria

- Users can set the top-K parameter for memory recall.
- The parameter is forwarded to the CLI.
