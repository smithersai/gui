# Design: independent validation checklist

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, task D3. Design-only. Ticket implementation runs through the `ticket-implement` smithers workflow, whose validation loop needs to decide when work is "done" beyond "tests pass." This ticket produces the checklist a reviewing agent uses to confirm completion independently.

## Why this matters

"Tests pass" is a necessary but not sufficient signal. A ticket can pass its own tests while failing to prove what the ticket claimed. The validation doc is the counter — it describes the specific, checkable things a reviewer (human or agent) looks for that the original implementer's tests may not have exercised.

## Goal

A written validation document at `.smithers/specs/ios-and-remote-sandboxes-validation.md` that the `ticket-implement` workflow's review step references.

## Scope of the output doc

- **Universal checks** — apply to every ticket in this initiative, regardless of type:
  - **Reference integrity.** Every file path, line reference, route path, and function name cited in the ticket's Context, References, or Scope sections actually exists and says what the ticket claims. A simple grep against the current tree must succeed for each. (This check was missed in an early review pass; 0095 cited the wrong header location.)
  - Changes actually match the ticket's stated scope (no scope creep, no scope cut).
  - Any new RPC / endpoint / wire format is documented in the spec it touches, not just in code.
  - Any new error class appears in the observability taxonomy (ticket 0098).
  - Any new metric appears in the observability doc.
  - Any test that could mock a dependency but doesn't mock one (good) is flagged; any test that mocks something it shouldn't (e.g., real PTY, real network disconnect) is flagged.
  - Commit messages and PR description reference the ticket number.
- **Per-category checks** — one short subsection per category:
  - **PoC tickets:** the PoC actually proves the claimed capability end-to-end, not a stub of it; tests are deterministic; README documents "what this proves" in the plue-PoC style; the implementation is minimal (no premature abstraction).
  - **Design tickets:** doc is at the specified path; every acceptance criterion is visibly satisfied inside the doc; cross-links to/from related specs exist.
  - **Implementation tickets (Stage 3+):** the PoC it depends on is referenced and its test still passes; the error taxonomy entry is hit in tests; no PII in logs; feature flag gate present if the rollout plan (D5) demands one.
- **Per-ticket expected-artifact table** — for each Stage 0 ticket, list the specific artifacts a reviewer confirms exist: test file paths, golden/fixture data paths, docker-compose diffs, README section titles, and for plue-side tickets the `*_test.go` locations. The ticket set is organized by category, not just "PoCs" — the table must reflect that:
  - **PoCs:** 0092, 0093, 0094, 0095, 0096, 0102, 0103, 0104.
  - **Plue implementation:** 0105 (quota), 0106 (OAuth2 authorize), 0107 (devtools), 0110 (approvals), 0111 (run shape), 0112 (feature flags). Plus any production-shape tickets added by the parallel planning pass.
  - **Client implementation:** 0109 (sign-in UI), 0113 (iOS productization). Plus desktop-remote productization and 0113 sub-splits added by the parallel planning pass.
  - **Design docs:** 0097, 0098, 0099, 0100, 0101, 0108.
  
  Each category gets its own row schema (e.g. PoC tickets need README "what this proves" section; implementation tickets need migration files if they touch DB schema). When new tickets land, the table is extended in a drive-by edit.
- **Review workflow hooks.** How this doc is consumed by `.smithers/workflows/ticket-implement.tsx`'s ValidationLoop review step. Specifically, the review prompt template should load this doc and answer per-category + per-ticket questions.
- **Escalation.** When a validation check fails, whether the workflow loops (ValidationLoop already handles this) or stops. Define stop conditions (e.g., 3 failed iterations => escalate to human).
- **Scope of this ticket vs. sibling tickets.** This ticket produces the doc and (if cheap) may patch sibling tickets to add cross-links. It does NOT retroactively edit sibling tickets' substantive content — other tickets remain their own owners' responsibility. Drive-by cross-link edits only.

## Acceptance criteria

- Doc lives at `.smithers/specs/ios-and-remote-sandboxes-validation.md`.
- Universal checks, per-category checks, and per-PoC expected-artifact table all present.
- Review workflow hooks section is concrete enough that `ticket-implement.tsx` can be edited to load this file into the review step.
- Cross-referenced from the main spec and the execution plan. Sibling tickets may (but do not have to) gain cross-link mentions via drive-by edits.

## Independent validation

Self-referential: this is the doc that defines validation. The reviewer for *this* ticket applies the universal checks above against itself.

## Out of scope

- Editing `ticket-implement.tsx` itself — that's implementation (follow-up ticket).
- Reviewing existing tickets retroactively — the checklist applies going forward.
