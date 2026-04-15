# Fix Terminal Key Event Forwarding Too Shallow

## Problem

The terminal view does not forward all key events to the underlying terminal
process. Modifier keys, function keys, and certain escape sequences are
dropped or misinterpreted.

Review: terminal.

## Current State

- `TerminalView` handles a subset of key events; others are swallowed by
  the SwiftUI responder chain.

## Proposed Changes

- Capture all key events (including modifiers, function keys, arrow keys)
  and forward them as proper escape sequences to the PTY.
- Ensure the SwiftUI key handling does not intercept terminal-bound keys.

## Files

- `TerminalView.swift`

## Acceptance Criteria

- All standard terminal key sequences (Ctrl+C, Ctrl+Z, arrows, function
  keys, Alt combinations) work correctly.
- No key events are silently swallowed.
