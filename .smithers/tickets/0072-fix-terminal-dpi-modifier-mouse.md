# Fix Terminal DPI/Modifier/Mouse Tracking Gaps

## Problem

The terminal emulator does not handle high-DPI scaling correctly, drops
some modifier key combinations, and has incomplete mouse tracking support.

Review: terminal.

## Current State

- Rendering may be blurry or misaligned on Retina displays.
- Some modifier combinations (e.g., Ctrl+Shift) are not forwarded.
- Mouse tracking modes (SGR, URXVT) are partially implemented.

## Proposed Changes

- Apply proper DPI scaling to the terminal render surface.
- Forward all modifier combinations as correct escape sequences.
- Implement SGR mouse tracking mode at minimum.

## Files

- `TerminalView.swift`
- Terminal emulator/parser files

## Acceptance Criteria

- Terminal renders crisply on Retina displays.
- All modifier key combinations produce correct escape sequences.
- Mouse tracking works for common modes (SGR at minimum).
