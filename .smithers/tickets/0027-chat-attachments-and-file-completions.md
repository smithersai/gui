# Add Chat Attachments And File Completions

## Problem

The TUI supports file and image attachments, paste handling, attachment
deletion, and `@` file completions. The GUI composer shows paperclip and `@`
icons, but they are not wired to equivalent behavior.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI source: `ChatView.swift`.
- TUI source of truth: `../tui/internal/ui/attachments`,
  `../tui/internal/ui/completions`, and related model key handlers.
- GUI paperclip and `@` controls are visual only or insert a marker.

## Goal

Add real GUI file/image attachment and file mention completion support.

## Proposed Changes

- Add file picker attachment support.
- Add image/paste attachment support where the model supports images.
- Add attachment list/chips with deletion and clear-all behavior.
- Add `@` file path completion.
- Include attachments/mentions in Codex requests according to TUI semantics.

## Acceptance Criteria

- GUI can attach one or more files.
- GUI can attach supported images.
- GUI can remove individual/all attachments.
- `@` opens file completion and inserts selected references.
- Requests sent to Codex include attachments/references correctly.

