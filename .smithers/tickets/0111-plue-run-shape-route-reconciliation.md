# Plue: run Electric shape + canonical route reconciliation

## Context

From `.smithers/specs/ios-and-remote-sandboxes.md` (Changes Needed In Plue → Additions #2) and the execution plan's PoC-B5. The spec commits to exposing run status as an Electric shape so clients sync passively instead of polling, and to picking one canonical route naming for the client contract. Plue today has the routes but inconsistent naming — `/api/repos/.../actions/runs/{id}` (inspect), `/api/repos/.../actions/runs/{id}/cancel` (cancel), `/api/repos/.../runs/{id}/logs` (log SSE), `/api/repos/.../workflows/runs/{id}/events` (event SSE) — and no Electric shape for run state.

## Problem

Without a run shape, clients must poll for status changes — defeating the Electric-first architecture. Without a single canonical naming, every client maintainer has to remember which of `/actions/runs/...`, `/runs/...`, `/workflows/runs/...` owns which operation.

## Goal

An Electric shape that delivers live run status + metadata to clients, plus a written naming decision (in code + spec) that picks one canonical prefix for the client-facing run routes.

## Scope

- **In scope**
  - **Electric shape** for the `runs` table (or equivalent — verify exact name in plue schema), filtered by `repository_id IN (...)` per auth proxy rules (`internal/electric/auth.go:47, 85`). Fields must include whatever status/progress/timestamps the client needs to render the run list + per-run status panel.
  - **Naming decision:** pick `/api/repos/.../runs/{id}[/cancel]` as the canonical public client surface. The existing `/actions/runs/...` and `/workflows/runs/...` paths stay, but gain sibling aliases at the canonical path or a deprecation note. Decision + rationale goes in the main spec's Run-control row of the changes-needed table.
  - **Log-event SSE naming:** pick `/api/repos/.../runs/{id}/events` as the canonical client surface, aliasing existing `/workflows/runs/{id}/events` (`internal/routes/workflow_runs.go:36`) or renaming. Document what the SSE payload schema actually is (`WorkflowRunLogsStream` emits only `log` events — `workflow_runs.go:53` hardcodes the event type; status/completion is inferred from payload fields, not separate SSE event types). If the client needs distinct `status`/`done` event kinds, that's an additional plue change to propose here.
  - **Tests:**
    - Shape delivers status transitions from `queued` → `running` → `completed`/`failed` in order to subscribed clients.
    - Shape filter enforces `repository_id` — wrong-repo subscription rejected.
    - Canonical routes return the same data as existing aliases.
- **Out of scope**
  - Adding new run functionality beyond what exists today.
  - Client-side rendering — a gui follow-up consumes this.
  - Deprecating the old paths — aliases only in this pass.
  - Reworking what `WorkflowRunLogsStream` emits — payload stays as-is.

## References

- `plue/cmd/server/main.go:785, 789, 1149, 1152, 1340` — existing run route registrations.
- `plue/internal/routes/workflow_runs.go:36` — `WorkflowRunLogsStream` handler.
- `plue/internal/routes/workflows.go:257` — workflow event SSE wiring.
- `plue/internal/electric/auth.go:47, 85` — Electric shape `repository_id` enforcement.

## Acceptance criteria

- Electric shape defined in plue and documented (shape name, table, `where` clause template).
- Canonical routes (`/api/repos/.../runs/{id}`, `.../cancel`, `.../events`) exist and return parity with existing aliases.
- Main spec updated (drive-by edit) to document the canonical naming and the SSE payload schema.
- Tests cover shape delivery + ACL + canonical-vs-alias parity.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the shape actually streams status transitions in order (not a collapsed-final-state-only view), cross-repo subscription is rejected at the auth proxy level, and the canonical/alias parity test uses the same underlying fixture — not separate fake data per path.

## Risks / unknowns

- Run table schema may need new columns to support useful shape-based rendering (progress percentage, current step, etc.). Out of scope to add fundamentally new data; add only what's already implicit.
- Two path aliases pointing at the same handler introduce test duplication; factor carefully.
