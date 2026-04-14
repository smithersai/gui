# Bring Prompts To Smithers Client Parity

## Problem

The GUI prompt implementation reads `.smithers/prompts` directly and discovers
props using a regex. The TUI uses the Smithers client for list/get/update,
property discovery, and preview. This risks drift from Smithers semantics.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI source: `PromptsView.swift` and prompt methods in `SmithersClient.swift`.
- TUI source of truth: `../tui/internal/ui/views/prompts.go`.
- TUI client support: `ListPrompts`, `GetPrompt`, `UpdatePrompt`,
  `DiscoverPromptProps`, and `PreviewPrompt` in
  `../tui/internal/smithers/prompts.go`.

## Goal

Route GUI prompt behavior through Smithers-compatible client methods.

## Proposed Changes

- Replace direct filesystem/regex behavior with Smithers client transports.
- Preserve filesystem fallback only if it matches TUI fallback behavior.
- Use Smithers prompt preview/rendering instead of simple string replacement.
- Ensure props discovery handles real Smithers prompt syntax.

## Acceptance Criteria

- Prompt list/get/update/preview behavior matches the TUI.
- Prop discovery matches Smithers runtime behavior.
- GUI prompt preview output matches TUI/CLI output for the same inputs.

