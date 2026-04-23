# Plue: approvals flow implementation

## Context

From `.smithers/specs/ios-and-remote-sandboxes.md` (Changes Needed In Plue → Additions #3). The main spec requires a first-class approvals entity (pending/approved/rejected/expired, tied to an agent session or run) plus an Electric shape for live client updates plus a decide endpoint. Ticket 0101 (rollout) allocates a `approvals_flow_enabled` feature flag for it. No implementation ticket existed until this one.

Ticket 0131 is a hard prerequisite for this work. Approval emission adds a new guest-agent RPC, so protocol negotiation and capability advertisement must land before `MethodEmitApprovalRequest` or any equivalent extension is introduced.

Today plue only has `protected_bookmarks.required_approvals` (`internal/db/` queries), which is branch protection — not the agent human-in-the-loop approval the spec wants.

## Problem

Without an approvals subsystem, the client can't implement the "agent wants to do X, do you consent?" UX pattern the main spec promises, and the rollout flag has no feature to gate.

## Goal

End-to-end approvals flow: agent runtime emits a pending-approval event → plue persists a row → client sees it via Electric shape → client POSTs decision → row updates → all connected clients see new state.

## Scope

- **In scope**
  - **Schema:** new `approvals` table. Fields (at minimum): `id`, `session_id` or `run_id` (whichever anchors the approval), `repository_id` (required for Electric auth), `state` (enum: `pending`, `approved`, `rejected`, `expired`), `kind` (machine-readable category — file write, shell command, network call, etc.), `title` (short user-facing), `description` (longer context), `created_at`, `decided_at`, `decided_by`, `expires_at`, `payload` (JSON blob of action-specific context).
  - **Decide endpoint:** `POST /api/repos/{owner}/{repo}/approvals/{id}/decide` accepting `{decision: "approved" | "rejected"}`. Route tests: valid decide succeeds, idempotent on repeat with same decision, rejects on repeat with different decision, rejects on expired, rejects when not authored for current user's scope.
  - **Emission:** after 0131 lands, guest-agent gets a new negotiated capability and protocol method (`MethodEmitApprovalRequest`) that the agent runtime calls when it needs approval. Guest forwards to plue; plue writes the row.
  - **Electric shape:** `approvals WHERE repository_id IN (...)` — matching plue's electric auth enforcement (`internal/electric/auth.go:47, 85`). Shape is pinned on the client side per spec section 4.
  - **Expiry policy:** decide: time-based (e.g. 10 min) or manual only? Document and implement. If time-based, a background sweeper updates `state` to `expired`; otherwise the client filters on `expires_at`.
  - **Tests:** service, route, and Electric-shape integration. Fan-out test: two fake clients see the same pending approval; one decides; both see the decided state.
- **Out of scope**
  - Client-side approvals UI (separate gui ticket; this only provides the surface).
  - Policy engine ("always approve file writes in trusted repos") — that's a follow-up.
  - Delegation / approve-on-behalf.
  - Audit log retention policies beyond what plue already does.

## References

- `plue/internal/electric/auth.go:47, 85` — repo-id enforcement for Electric shapes.
- `plue/internal/sandbox/guest/protocol.go:15` — guest-agent protocol enum (fixed; version negotiation owned by ticket 0131).
- `plue/internal/sandbox/guest/handler.go:86` — handler dispatch.
- `plue/internal/routes/agent_sessions.go` — pattern to follow for a new SSE-adjacent route if the shape alone isn't sufficient.

## Acceptance criteria

- `approvals` table migrated.
- Ticket 0131 has landed, and approval emission is gated by the negotiated guest-agent capability it defines.
- `POST /api/repos/{owner}/{repo}/approvals/{id}/decide` route exists with full test coverage.
- Guest-agent emits a pending approval; plue persists; Electric shape delivers it to a test client.
- Two-client fan-out test passes.
- Expiry model documented and implemented.
- Approvals shape honors `repository_id IN (...)` — rejected shapes don't leak across repos.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the decide endpoint is idempotent on same decision and rejects on conflicting decision; the expiry sweeper (if implemented) doesn't race the decide endpoint; emissions from guest-agent actually round-trip to Postgres (not stubbed).

## Risks / unknowns

- **Depends on 0131.** This ticket must not add a new guest-agent method until ticket 0131's handshake/capability negotiation is in place. Approval emission should be keyed off negotiated capability, not deployment ordering.
- Whether approvals are anchored to sessions or runs (or both) affects schema; decide early.
- Payload size bounding — approval context can get big (diffs, file tree snippets). Cap it or offload to blob.
