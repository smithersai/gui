# Plue: audit logging for human-in-the-loop approvals

## Status (audited 2026-04-24) — PARTIAL

- Done: Approvals table landed (4308aefb8); handlers wired per 0155.
- Remaining: Immutable audit events for create/approve/reject/expire lifecycle not yet verified emitting; retention/query surface absent.

## Context

Ticket 0110 adds the approvals entity and the decide route, but it explicitly leaves audit logging out of scope (`/Users/williamcory/gui/.smithers/tickets/0110-plue-approvals-implementation.md:26-30`). That creates a gap for a security-sensitive action: the mutable `approvals` row may tell the UI the current state, but it is not an immutable audit trail of who approved what and when.

Plue already has almost all of the plumbing needed:

- `services.NewAuditService(queries)` is wired into the server at `plue/cmd/server/main.go:191`.
- `plue/internal/services/audit.go:18-77` writes structured audit events into `audit_log`.
- `GET /api/admin/audit-logs` is already exposed at `plue/cmd/server/main.go:1412` and implemented in `plue/internal/routes/admin_audit.go:23-61`.
- The underlying query currently supports only `since` + pagination (`plue/internal/db/audit_log.sql.go:80-94`), which is enough for generic browsing but weak for retrieving one approval decision later.

## Goal

Record immutable audit events for approval creation and decision, and make those events practically retrievable later when someone needs to answer “who approved this action?” or “when was this approval rejected?”

## Scope

- **In scope**
  - Emit audit events for the approval lifecycle owned by 0110:
    - pending approval created.
    - approval approved.
    - approval rejected.
    - approval expired or system-cancelled, if 0110 implements expiry.
  - Use the existing audit table and service rather than inventing a second audit store.
  - Standardize event naming and targets, for example:
    - `approval.requested`
    - `approval.approved`
    - `approval.rejected`
    - `approval.expired`
    - `target_type = "approval"`
    - `target_id = approvals.id`
  - Define minimal metadata so later retrieval is useful without dumping sensitive payloads into the audit log:
    - `repository_id`
    - `session_id` and/or `run_id`
    - `kind`
    - `decision`
    - `expires_at`
    - stable identifiers or hashes for any large approval payload
  - Improve retrieval enough that operators can find approval events later, either by extending the admin audit query with filters (`event_type`, `target_type`, `target_id`, maybe `actor_id`) or by adding an equivalent filtered admin surface.
  - Tests covering event emission and retrieval.
- **Out of scope**
  - End-user approval history UI in the gui client.
  - Changing audit retention from the current cleanup policy.
  - Dumping full approval payloads, diffs, or screenshots into audit metadata.

## References

- `/Users/williamcory/gui/.smithers/tickets/0110-plue-approvals-implementation.md:19-25` — approvals lifecycle to audit.
- `/Users/williamcory/gui/.smithers/tickets/0110-plue-approvals-implementation.md:26-30` — audit logging is explicitly out of scope there today.
- `plue/cmd/server/main.go:191` — audit service is already constructed.
- `plue/internal/services/audit.go:18-77` — reusable audit writer.
- `plue/cmd/server/main.go:1412` — admin audit-log route registration.
- `plue/internal/routes/admin_audit.go:23-61` — current retrieval surface.
- `plue/internal/db/audit_log.sql.go:48-94` — audit table insert + list queries today.
- `plue/internal/db/models.go:81-93` — `AuditLog` row shape returned to admins.

## Acceptance criteria

- Approval create/approve/reject/expire paths emit audit events via the existing `AuditService`.
- Audit rows capture actor identity for human decisions and a nil/system actor for system-created or system-expired approvals.
- Metadata is useful for later investigation but intentionally redacts or hashes sensitive approval context instead of copying it wholesale.
- Admin retrieval is practical: reviewer can query for approval-specific events without paging through unrelated audit rows.
- Tests cover:
  - create event written.
  - approve event written with deciding user.
  - reject event written with deciding user.
  - retrieval surface filters down to approval events.
  - sensitive payload fields are not copied verbatim into audit metadata.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the decision route and any expiry worker both emit audit rows, checks that retrieval is better than “dump every audit log since last week,” and confirms the metadata does not leak raw approval payloads.

## Risks / unknowns

- If 0110 has not yet decided whether approvals are anchored to sessions, runs, or both, the audit metadata should carry whichever identifiers exist without waiting for a perfect schema.
- Audit metadata can become a second copy of sensitive context if we are careless. Favor identifiers, hashes, and short summaries over raw blobs.
- If admin-only retrieval is insufficient for the product, that should become a separate user-facing history ticket rather than quietly bloating this one.
