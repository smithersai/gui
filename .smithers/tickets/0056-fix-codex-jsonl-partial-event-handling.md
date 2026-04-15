# Fix Codex JSONL Partial Event Handling

## Problem

The Codex JSONL event parser does not handle partial lines correctly. When a
JSON event spans multiple read chunks, the parser can drop or corrupt the
event.

Reviews: platform, codex_events.

## Current State

- The parser splits on newlines and attempts to decode each line, but does
  not buffer incomplete lines across reads.

## Proposed Changes

- Add a line buffer that accumulates partial data until a complete line
  (terminated by newline) is available.
- Only attempt JSON decoding on complete lines.

## Files

- Codex event parsing files
- `SmithersClient.swift` (if parsing is inline)

## Acceptance Criteria

- Partial JSONL lines are buffered and decoded correctly.
- No events are dropped or corrupted due to chunk boundaries.
