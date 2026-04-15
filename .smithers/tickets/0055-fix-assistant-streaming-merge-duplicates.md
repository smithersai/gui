# Fix Assistant Streaming Merge Duplicates Text

## Problem

When streaming assistant responses, text chunks are merged incorrectly,
causing duplicated text in the chat display.

Review: chat.

## Current State

- Streaming deltas are appended without checking for overlap with the
  previous content, resulting in repeated text segments.

## Proposed Changes

- Track the last appended offset or use delta indices to avoid duplication.
- Verify the merge logic handles out-of-order or retransmitted chunks.

## Files

- Chat view files
- `SmithersModels.swift` (ChatBlock content merging)

## Acceptance Criteria

- Streamed assistant text displays without duplication.
- Out-of-order chunks are handled gracefully.
