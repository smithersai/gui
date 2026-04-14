# Add Codex MCP Listing Parity

## Problem

The TUI displays configured MCP tools/status. The GUI `/mcp` slash command only
reports that MCP tool listing is not exposed by the current bridge.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI placeholder: `ChatView.swift` appends "MCP tool listing is not exposed by
  the current Codex FFI bridge yet."
- TUI MCP status/model support lives under `../tui/internal/ui/model/mcp.go`
  and Smithers MCP status helpers.

## Goal

Expose MCP tools/status in the GUI.

## Proposed Changes

- Extend the Codex FFI or GUI service layer to retrieve MCP tool/server status.
- Add an MCP panel or dialog.
- Show configured server names, transport/status, and available tools where the
  TUI does.
- Replace `/mcp` placeholder with the real surface.

## Acceptance Criteria

- `/mcp` opens or displays real MCP status.
- GUI output matches the TUI for the same configuration.
- Errors from unavailable MCP servers are visible but non-fatal.

