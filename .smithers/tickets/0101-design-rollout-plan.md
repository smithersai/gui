# Design: rollout plan

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, task D5. Design-only. The migration (D4) produces a sequence of internal changes. This document describes how those internal changes reach real users, what order shipping happens in, and how we catch problems before they reach everyone.

## Goal

A written rollout plan at `.smithers/specs/ios-and-remote-sandboxes-rollout.md` covering feature ordering, feature flags, canary cohorts, kill switches, and per-phase acceptance gates.

## Scope of the output doc

- **Phasing of user-facing features.** Proposed default phase order (doc should confirm or revise):
  1. **Desktop-remote mode in private build.** Internal-only. Desktop app can connect to a JJHub sandbox while retaining local mode. All new surfaces (run shape reconciliation, approvals, devtools snapshot) gated behind flags. Duration: until all PoCs are green and migration is through step N.
  2. **Desktop-remote mode to alpha whitelist.** Subset of whitelisted users get the new feature. Kill switch available.
  3. **iOS app to alpha whitelist.** Same whitelist. TestFlight distribution.
  4. **Local-desktop-only users migration.** Blocked on the separate desktop-local spec.
  5. **General availability** (still whitelist-gated per main spec: access is always gated by JJHub whitelist).
- **Android is NOT in the rollout phase list.** The main spec commits to an Android *WIP build* as an architectural canary (no user-facing shipment); this rollout doc does not schedule Android user releases. If later that guardrail is relaxed, a new phase is added.
- **Feature flags — plue's current capabilities vs. what this rollout proposes.**
  - **Current state:** plue's feature-flag surface is a fixed set of global env-backed booleans defined in `internal/config/config.go:53` and exposed at `/api/feature-flags` via `internal/routes/flags.go` (see the flag list inlined there for the exact names). There is no per-user or per-cohort toggling today. None of the flags names this ticket proposes exist yet.
  - **Proposed new flags (all are plue prerequisites that must ship before the rollout can use them):** `remote_sandbox_enabled`, `electric_client_enabled`, `approvals_flow_enabled`, `devtools_snapshot_enabled`, `run_shape_enabled`. All global booleans. The flag *set* is added to plue by ticket 0112. Each flag also has an owning implementation ticket for the behavior it gates:
    - `remote_sandbox_enabled` → umbrella for all iOS/remote client work (currently 0113 iOS productization; desktop-remote productization ticket to be added by the parallel planning pass).
    - `electric_client_enabled` → production-surface Electric shape tickets (separate from 0093/0096 which are PoCs). Production shape tickets for `agent_sessions`, `agent_messages`, `workspaces`, `workspace_sessions` are to be added by the parallel planning pass.
    - `approvals_flow_enabled` → ticket 0110 (plue approvals implementation).
    - `devtools_snapshot_enabled` → ticket 0107 (plue devtools snapshot surface).
    - `run_shape_enabled` → ticket 0111 (plue run shape + route reconciliation).
  - The rollout doc cannot reference any flag whose owning implementation ticket does not exist. Any flag mapping marked "to be added by the parallel planning pass" must resolve to a concrete ticket before the rollout doc is considered complete.
  - **Per-user / per-cohort gating:** not assumed. The rollout doc must either:
    - (a) Scope rollout to what global booleans can achieve (coarse on/off per feature; cohort behavior achieved by distributing different builds to different user groups), OR
    - (b) List as a named prerequisite ticket: "plue gains per-user feature-flag scoping," with that work done before Phase 2.
    Pick one explicitly in the doc.
- **Canary cohorts.** How we pick the first N users per phase, how consent is captured, what telemetry they must have enabled to be eligible. Answers the "who's getting it first and why" question explicitly.
- **Kill switches.** For each feature flag, the kill path. Typically: flip the flag off on the server side. Document expected rollback latency.
- **Per-phase acceptance gates.** Machine-checkable signals that let a phase advance. Example: no `auth_revoked` errors exceeding baseline, no `electric_shape_reconnect_count` > threshold, crash rate below X on new builds.
- **Internal vs. external comms.** When and how we announce each phase — internal Linear status, changelog, release notes, etc.
- **Deprecation of today's features.** What we tell users about current local-mode behavior changing. Timeline for removing legacy code paths after each phase proves stable (tied to D4 migration steps).

## Acceptance criteria

- Doc lives at `.smithers/specs/ios-and-remote-sandboxes-rollout.md`.
- Every phase has: entry criteria, exit criteria, kill switch plan, owner.
- Every feature flag is named + described + has default values per phase.
- Cross-linked with D4 (migration) — rollout phases and migration steps must align.
- Reviewed and approved before Stage 1 PoCs begin production wiring (Stage 0 PoCs can proceed without this).

## Independent validation

See D3 (`ticket 0099`). Until D3 lands: reviewer confirms every phase has a kill switch (not just an off-switch), every feature flag has a named owner, and the "whitelist is always on" constraint from the main spec isn't accidentally relaxed.

## Out of scope

- Implementing feature flags — that's implementation (follow-up if plue doesn't already support it).
- Picking specific canary users — done at rollout time, not in the doc.
- Marketing / launch announcements — out of engineering scope.
