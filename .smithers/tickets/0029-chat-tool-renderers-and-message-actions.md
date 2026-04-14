# Add Chat Tool Renderers And Message Actions

## Problem

The TUI has detailed renderers for tool calls/results, assistant thinking,
todos, diagnostics, MCP tools, references, diffs, fetch/search/file/bash tools,
plus copy, expand/collapse, and details panel behavior. The GUI currently has a
much thinner message model.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI source: `AgentService.swift`, `ChatView.swift`, and message row models.
- TUI source of truth: `../tui/internal/ui/chat`.
- GUI handles only a subset of Codex events: assistant messages, command
  execution, and file-change status.

## Goal

Port rich chat message rendering and common message actions to the GUI.

## Proposed Changes

- Map Codex events to richer GUI message item types.
- Add dedicated renderers for bash, file, search, fetch, agent, diagnostics,
  references, LSP restart, todos, MCP, and generic tools.
- Add assistant thinking/error rendering parity.
- Add expand/collapse where TUI supports compact items.
- Add copy/select behavior for message content and tool outputs.
- Add a details panel equivalent if supported by GUI layout.

## Acceptance Criteria

- Tool calls/results are recognizable and readable in GUI chat.
- Message rendering covers the same tool categories as the TUI.
- Users can copy relevant message/tool content.
- Long/compact content can be expanded according to TUI semantics.

