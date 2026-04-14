# Port Tickets Workflow To GUI

## Problem

The TUI has local Smithers ticket management: list, search, create, detail, edit,
update, and delete. The GUI has no tickets view or client methods.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- TUI source of truth: `../tui/internal/ui/views/tickets.go` and
  `../tui/internal/ui/views/ticketdetail.go`.
- TUI client support: `ListTickets`, `GetTicket`, `CreateTicket`,
  `UpdateTicket`, `DeleteTicket`, and `SearchTickets` in
  `../tui/internal/smithers/tickets.go`.
- GUI has no `TicketsView.swift`.

## Goal

Add GUI support for Smithers tickets.

## Proposed Changes

- Add `NavDestination.tickets` and `TicketsView.swift`.
- Add ticket client methods.
- Support ticket list, search/filter, create flow, detail view, edit/save, and
  delete.
- Preserve local Markdown content semantics.

## Acceptance Criteria

- GUI lists existing tickets from `.smithers/tickets`.
- GUI can create a new ticket.
- GUI can view and edit ticket Markdown.
- GUI can delete tickets.
- Search/filter behavior matches the TUI.

