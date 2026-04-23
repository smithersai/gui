# Design: dispatch-run semantics

## Context

From `.smithers/specs/ios-and-remote-sandboxes.md` (Changes Needed In Plue → Agent sessions). Plue's public repo-scoped API on `agent_sessions.go` has **no explicit `/dispatch-run` route**. Run dispatch happens implicitly when a `user`-role message is posted (`agent_sessions.go:280`). An earlier draft of the spec claimed an explicit `/dispatch-run` route exists; Codex flagged that as wrong. This ticket decides what the spec's actual posture should be.

## Problem

There are two reasonable client contracts:

**Option A — Keep implicit.** Document the current behavior as canonical: "posting a user message dispatches a run." Pro: no plue change needed. Con: less-obvious client contract; clients can't easily post a user message without triggering a run (e.g. to amend before dispatch); harder to reason about what counts as "sending."

**Option B — Add an explicit `/dispatch-run` route.** Con: plue change, new endpoint, new test. Pro: clean client contract; clients can stage messages and dispatch separately; matches the spec's original claim.

Either is viable. This ticket forces a decision and documents it before any client code depends on one.

## Goal

A short written decision document at `.smithers/specs/ios-and-remote-sandboxes-dispatch-run.md` that:

- Picks Option A or Option B with a rationale.
- Documents the chosen client contract (what does "send a message" mean? when does a run dispatch?).
- Updates the main spec to match.
- If Option B, names the plue follow-up ticket to add the route.

## Scope of the output doc

- Clear statement of the chosen option and why.
- Concrete API-level description of the chosen client contract: which request(s) the client issues, in what order, what the server returns, what state transitions happen.
- Identification of the plue-side work required (none for A; a real new handler for B).
- Update to the main spec's agent-sessions section so it matches the chosen contract.

## Acceptance criteria

- Doc lives at `.smithers/specs/ios-and-remote-sandboxes-dispatch-run.md`.
- Main spec updated in a drive-by edit so it no longer asserts a non-existent route (if Option A) or documents the new route (if Option B).
- If Option B, a new plue implementation ticket exists.
- Reviewed and approved before any ticket that writes code against run dispatch begins.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the decision document's client-contract section actually matches `agent_sessions.go:280`'s current behavior (if Option A) or specifies a new route that doesn't duplicate existing behavior (if Option B).

## Out of scope

- Implementation of Option B's route. If that's the choice, it's a follow-up ticket.
- Cancellation semantics — those are covered by existing cancel routes + ticket B5.
- Run event trace format — handled by PoC-B5 (run shape + route reconciliation).
