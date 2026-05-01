# Plue: enforce 100-sandbox-per-user quota

## Context

From `.smithers/specs/ios-and-remote-sandboxes.md` (Sandbox Lifecycle UX → Quota section). The main spec states:

> Every authenticated user is allowed up to 100 sandboxes. No payment or plan tiers in this pass.
> Plue enforces the quota on `POST /api/repos/{owner}/{repo}/workspaces`; attempting to create a 101st returns a structured error that the client renders as "you've reached your sandbox limit — delete one to continue."

Codex's review flagged this as a user-facing promise with no implementation ticket behind it. The plue bill-of-materials lists "sandbox quota enforcement" as a delta, but no ticket actually implements it. This ticket closes that gap.

## Problem

Plue today does not cap workspace count per user. `POST /api/repos/{owner}/{repo}/workspaces` (handled in `internal/services/workspace_provisioning.go:118`) creates or resumes a workspace without consulting any per-user cap. Complicating the picture:

- `POST .../workspaces` on a repo where the user already has a workspace often **reuses** the primary workspace instead of creating a new one (`workspace_provisioning.go:131`). Enforcement must not falsely count reuse as a new create.
- Workspaces can also be produced via `POST .../workspaces/{id}/fork`. That path must count too.
- `DeleteWorkspace` today **only stops the VM and leaves the row** (`internal/services/workspace_lifecycle.go:53`). If deleted rows stay in the count, "delete one to continue" is a broken promise.

## Goal

Decide the workspace lifecycle state model, add a hard cap of 100 active workspaces per authenticated user at every create path, and make "delete one to continue" actually work. Return a structured error when exceeded.

## Scope

- **In scope**
  - **Decide first:** does `DeleteWorkspace` transition to a `deleted` terminal state that this count excludes, OR does it become a hard delete? Document the choice, implement it, update the spec's UX copy accordingly.
  - Plue-side count check: a single query counting "non-deleted workspaces owned by user" called from every creator path. At a minimum: `CreateWorkspace` (`workspace_provisioning.go:118`), `ForkWorkspace` (the `.../fork` route's service entry), and any other path introducing a new workspace row.
  - **Reuse path does not count:** if `CreateWorkspace` decides to reuse the primary workspace (`workspace_provisioning.go:131`), the count check is bypassed — the user isn't actually creating anything new.
  - New structured error class `quota_exceeded` (or reuse an existing one if apt). Payload matches plue's normal structured error shape.
  - Tests:
    - Create up to 99 (succeeds), 100 (succeeds), 101 (fails with expected error).
    - Delete one — verify state transition matches the chosen model, count drops, next create succeeds.
    - Fork path hits the cap too.
    - Reuse path does not count against the cap.
    - Both unit-level on the service and integration-level through the HTTP route.
  - Cap is a named constant, not a magic number — easy to change later.
  - No payment / plan tier logic. Everyone gets 100.
- **Out of scope**
  - Per-org or per-repo quotas.
  - Billing integration.
  - Per-user overrides (admin-granted higher caps) — follow-up if anyone actually needs it.
  - Retroactive cleanup of over-quota users (shouldn't exist today, but this ticket does not delete anything retroactively; it just prevents new creates past the cap).
  - Quota for agent sessions, runs, approvals — separate concerns.

## References

- `plue/internal/services/workspace_provisioning.go:118` — `CreateWorkspace` service entry.
- `plue/internal/routes/workspace.go:68–251` — the HTTP handler that calls the service.
- `plue/pkg/errors/` (or wherever plue puts structured errors) — error shape to match.

## Acceptance criteria

- New constant defines the cap at 100.
- `CreateWorkspace` in the service layer counts existing workspaces owned by the requesting user and rejects with a structured `quota_exceeded` error when the count is already at the cap.
- Route-level test: 101st create attempt returns a 4xx with the documented error body.
- Service-level test: the count query uses an indexed lookup, not a full scan (if the existing DB has no suitable index, add it as part of this ticket).
- README or inline comment at the cap constant explains that this is a placeholder-for-payment-tiers-later, not a permanent architecture decision.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the test actually creates 100 workspaces (not mocks the count), and the route-level test exercises the real HTTP handler path, not the service directly.

## Risks / unknowns

- Counting workspaces per user on every create is cheap for small N but can regress if N grows unbounded for other reasons. Indexed lookup is the mitigation.
- Deletion is soft vs. hard in plue — the count must match whichever semantic the spec promises ("delete to free up a slot"). Verify before implementing.
