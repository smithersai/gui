# Plue: `agent_parts` production Electric shape

## Context

`agent_messages` alone is not enough to rebuild a transcript. The actual per-message content lives in exact table `agent_parts` (`plue/db/migrations/000001_baseline.sql:756-768`), and plue’s API/service layer always joins parts back in before returning chat history (`internal/services/agent.go:45-52`, `625-714`). The main spec’s bounded-SQLite transcript model therefore needs a production shape for `agent_parts`, even though the original synced-entity list only named sessions and messages.

## Problem

- There is no production shape ticket for `agent_parts`, so a client following only `agent_sessions` + `agent_messages` would have message order but not message bodies.
- `agent_parts` has neither `repository_id` nor `session_id`, so raw-table shaping fails both the Electric auth requirement and the practical need for per-session subscriptions.
- Part cardinality tracks message cardinality and includes JSON payloads for `text`, `tool_call`, and `tool_result`; repo-wide sync would be wasteful.
- There is no independent delete route for parts today. Their lifetime follows the parent session/message.

## Goal

Ship a production Electric shape for exact table `agent_parts` so chat content, tool calls, and tool results can be restored from synced local SQLite.

## Scope

- **In scope**
  - Shape exact table `agent_parts`.
  - Add `repository_id BIGINT NOT NULL` and `session_id UUID NOT NULL` to `agent_parts`, backfilled by joining `agent_parts -> agent_messages -> agent_sessions`.
  - Populate both denormalized fields on every insert path. `CreateAgentPart` is called from the same append paths used for user messages and runner events (`internal/services/agent.go:526-541`, `588-600`, `748-795`).
  - Add an index supporting the production filter, e.g. `(repository_id, session_id, message_id, part_index)`.
  - Shape where-clause template: `repository_id IN (<repo_ids>) AND session_id IN (<open_session_ids>)`.
  - Subscription policy:
    - Same lifecycle as 0115’s `agent_messages` shape.
    - Open-chat only; no repo-wide sync of all parts.
    - Evict by LRU when a chat tab closes.
  - Client consumers:
    - Transcript body rendering.
    - Tool-call / tool-result blocks.
    - Restore/reopen of historical chat content in the local cache.
  - Delete semantics:
    - No part-level tombstone in v1.
    - Parent session tombstone from 0114 triggers local purge of matching `agent_parts` rows.
    - If message edit/delete is ever added, revisit this and add explicit part-level tombstones then.
  - Tests:
    - Migration/backfill test for `repository_id` and `session_id`.
    - Insert-path tests proving new parts carry both denormalized fields.
    - Shape auth tests for good repo, bad repo, and missing repo filter.
    - Multi-client fan-out test covering `text`, `tool_call`, and `tool_result` payloads.
- **Out of scope**
  - Message envelope/order; that remains 0115.
  - Any privacy-model change to repo-readable chat transcripts.
  - Client rendering details.

## References

- `.smithers/specs/ios-and-remote-sandboxes.md:186-194`, `266-269`
- `plue/internal/electric/auth.go:47-50`, `85-100`, `250-282`
- `plue/internal/routes/agent_sessions.go:222-340`
- `plue/internal/services/agent.go:45-52`, `526-541`, `588-600`, `625-714`, `748-795`
- `plue/internal/db/agent.sql.go:85-128`, `287-318`
- `plue/db/migrations/000001_baseline.sql:756-768`

## Acceptance criteria

- `agent_parts` has a documented production shape definition with exact table name and `where` template.
- The table carries backfilled `repository_id` and `session_id`, and new inserts populate both.
- Transcript restore tests can read full message bodies from the local cache model that mirrors `agent_messages` + `agent_parts`.
- A plue integration test appends messages with multiple part types and verifies two subscribed clients receive the part rows for the targeted session only.
- Electric auth tests confirm raw `agent_parts` shapes are rejected without a repo filter and accepted only for authorized repos.

## Independent validation

See ticket 0099. Until 0099 lands, reviewer verifies:

- The test data includes non-text parts (`tool_call` / `tool_result`), not only plain text.
- Session scoping is real: opening session A does not replicate parts from session B in the same repo.
- The migration backfill uses the parent-table join path and leaves no null `repository_id` / `session_id` rows behind.

## Risks

- `agent_parts.content` is JSONB and can grow quickly for large tool payloads; size and indexing need scrutiny.
- Repo-readable transcript content may already be more permissive than the eventual product wants. This ticket should not hide that mismatch.
- Without 0115, this table is not useful on its own; both tickets must land together for transcript sync to work.
