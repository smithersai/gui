# Add Real Approval History And Payloads

## Problem

The GUI approvals view synthesizes pending approvals from run inspection and
returns an empty decision history. This loses payload, metadata, resolved
decision history, and the TUI's real approval transport behavior.

Assume the TUI behavior is correct and the GUI is incomplete.

## Current State

- GUI `listPendingApprovals` synthesizes approvals from waiting runs.
- GUI `listRecentDecisions` returns `[]`.
- TUI source of truth: `../tui/internal/ui/views/approvals.go`.
- TUI client support: `ListPendingApprovals`, `ListRecentDecisions`,
  `Approve`, and `Deny` in `../tui/internal/smithers/client.go`.

## Goal

Make GUI approvals use the real Smithers approval sources and preserve payload
and decision history.

## Proposed Changes

- Implement real pending approvals transport using the same fallback order as
  the TUI: HTTP, SQLite, then supported exec behavior.
- Implement recent decision history.
- Preserve payload JSON, requested/resolved metadata, and resolver fields.
- Keep synthetic fallback only when no real transport exists and label it
  clearly if used.

## Acceptance Criteria

- Pending approvals include payload and metadata when available.
- History mode shows recent approved/denied decisions.
- Approve/deny actions use the same semantics as the TUI.
- The GUI does not silently discard approval context.

