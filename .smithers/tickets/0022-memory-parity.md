# Bring Memory View To TUI Parity

## Problem

The GUI memory view has basic fact listing and semantic recall, but appears less
complete than the TUI's all-namespace/SQLite-backed memory browser and recall
workflow.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI source: `MemoryView.swift`.
- TUI source of truth: `../tui/internal/ui/views/memory.go`.
- TUI client support: `ListAllMemoryFacts`, `ListMemoryFacts`, and
  `RecallMemory` in `../tui/internal/smithers/client.go`.

## Goal

Close the memory feature gap between GUI and TUI.

## Proposed Changes

- Verify GUI list mode uses all-memory semantics where the TUI does.
- Add namespace and workflow-path scoping parity.
- Ensure direct SQLite and exec fallback behavior matches the TUI.
- Match detail metadata, pretty JSON rendering, TTL display, and recall result
  behavior.

## Acceptance Criteria

- GUI memory list matches TUI memory list for the same data source.
- GUI namespace filtering matches TUI behavior.
- GUI recall request arguments match TUI/Smithers CLI behavior.
- Fact detail metadata and TTL display match TUI semantics.

