# Fix Terminal Clipboard Support Incomplete

## Problem

Terminal clipboard operations (copy/paste via OSC 52 or selection) are not
fully implemented, preventing users from copying output or pasting input.

Review: terminal.

## Current State

- OSC 52 clipboard sequences may be ignored.
- Selection-based copy is incomplete or missing.

## Proposed Changes

- Implement OSC 52 read/write handling in the terminal emulator layer.
- Wire native pasteboard for copy on selection and paste on Cmd+V.

## Files

- `TerminalView.swift`
- Terminal emulator/parser files

## Acceptance Criteria

- Users can copy terminal output via selection.
- OSC 52 clipboard sequences work.
- Cmd+V pastes into the terminal.
