# Dispatch-run semantics — decision

## Chosen option

**Option A: keep the current implicit behavior.** Posting a `user`-role message to an existing agent session **is** the act of dispatching a run; plue's current handler (`internal/routes/agent_sessions.go:269–293`) appends the message and, if `role == "user"`, immediately calls `services.AgentService.DispatchAgentRun`. We document this as the canonical client contract and do **not** add an explicit `/dispatch-run` route.

## Rationale

- **Zero plue change.** The behavior already exists and is exercised by plue's own tests. No new route, handler, test, docs, feature flag, or deprecation pathway.
- **No duplicate API surface.** Adding an explicit `/dispatch-run` alongside the implicit dispatch would give us two ways to start a run, which drift apart: different validation, different logging, different metrics. That divergence is exactly the class of bug that shows up only in production.
- **The "stage messages then dispatch" use case is speculative.** Option B's only real benefit is letting a client append several messages and then explicitly fire one run. We have no product requirement for that in v1: the iOS client, the Mac client, and the existing web client all follow the pattern of "type a message, send, watch the run happen."
- **The observability gap is solvable without a new route.** The client learns that a run was dispatched because the message POST returns `201` with the persisted message, and — once ticket 0111 lands — the `workflow_runs` Electric shape surfaces the new row with `trigger_message_id = <that message's id>`. SSE-based event streams (`WorkflowRunLogsStream`, agent session stream) carry the live trace. No separate "run was dispatched" response payload is needed.

Rejected: Option B (explicit `/dispatch-run`). Cost would have been: (a) a new plue handler + service wiring (est. 0.5d), (b) a new integration test, (c) a deprecation window for the implicit behavior or a feature flag to toggle between the two (2wk+ of coordination), and (d) client-side branching while the flag exists. All of that to buy an ergonomic niceness nobody has asked for.

## Client contract

### Request

The client creates (if needed) and then appends a message; appending a `user`-role message dispatches a run.

1. `POST /api/repos/{owner}/{repo}/agent/sessions` — create session. Returns `AgentSessionResponse` with an `id` (UUID string). **Does not dispatch a run.**
2. `POST /api/repos/{owner}/{repo}/agent/sessions/{id}/messages` with body `{ "role": "user", "parts": [...] }` — appends the message **and** dispatches a run as a single server-side atomic-ish step (two DB transactions, but the handler fails the whole request if dispatch fails; see `agent_sessions.go:289–292`).

Appending `role: "assistant"` or `role: "tool"` messages does **not** dispatch a run; the server returns `201` with the persisted message and nothing else happens. (Practically these are written by the runner via `IngestRunnerEvent`, not by clients, but a misbehaving client appending a non-user message will not accidentally trigger a run.)

### Response

`POST .../messages` returns `201 Created` with the `AgentMessageResponse` JSON: `{id, session_id, role, sequence, parts, created_at}`. **It does not include the dispatched `workflow_run_id`.** The client discovers the run via its Electric subscription (below) rather than via this response. If the caller needs the `workflow_run_id` synchronously it must read it from the shape; blocking on a synchronous dispatch result is not supported.

### State transitions

On success:

| Step | Table | Before → After |
|---|---|---|
| Message insert | `agent_messages` | — → new row, role=`user`, sequence=next |
| Run create | `workflow_runs` | — → new row, status=`pending`, trigger via the new `trigger_message_id` column landing in ticket 0114/0115 reconciliation |
| Task create | `workflow_tasks` | — → new row, status=`queued` |
| Session status | `agent_sessions` | previous terminal/idle → `running` (via `transitionAgentSessionStatus` inside the dispatch flow) |
| Agent token | `workflow_runs.agent_token_hash` | null → sha256 of freshly minted token (token itself is NOT persisted) |

On dispatch failure (e.g. snapshot creation fails, sandbox backend rejects), the handler returns a non-2xx and — critically — the already-inserted message **stays**. The client sees the `user` message but no run. This is a known property of the current implementation; see ticket 0115's agent-messages production-shape work for the cleanup discussion. For this spec, "appended but not dispatched" is treated as an error the client surfaces via the normal HTTP error path, not as a separate resumable state.

### How the client observes the run

1. **Electric shapes (canonical).** The client is already subscribed to `workflow_runs` filtered by its visible `agent_sessions`. The new row appears in the local SQLite cache via the shape delta within one shape poll interval. Shape join: `workflow_runs.trigger_message_id = agent_messages.id`.
2. **SSE traces (live tail).** For the live event feed the client opens `GET /api/repos/{owner}/{repo}/workflows/runs/{id}/events` (existing plue route) once the shape has surfaced the `id`. This is optional — the shape alone is enough for a UI that is happy with ~second-granularity updates.
3. **Session-level SSE (fallback).** `agent_session_stream.go` exposes per-session event streaming that predates the shape work. Clients that want push-latency without running a separate SSE per-run can subscribe at the session level.

## Plue-side work required

**None.** Current code (`agent_sessions.go:269–293` + `services/agent.go:724 DispatchAgentRun`) is the implementation of record. Verified against commit state as of ticket 0108.

No new plue implementation ticket is created by this decision.

## Update to main spec

Driveby edits in `ios-and-remote-sandboxes.md`:

- §"Changes Needed In Plue → Agent sessions" (line 120) — the existing note already calls out the implicit dispatch and forward-references ticket 0108. Replaced the "Whether we document-and-keep…is tracked as ticket 0108" sentence with the resolution and a link to this doc.
- §Transport → "Plain HTTP + JSON" (line 88) — replaced the "ticket 0108 decides whether to keep that or add an explicit route" sentence with a statement that the implicit behavior is canonical, plus a link to this doc.
- §"Summary: changes-needed bill of materials" (line 164) — no change needed; the "Run control" row already says "dispatch…present."

Grep for `/dispatch-run` after edits → no remaining non-this-doc references.

## Impact on sibling tickets

- **0111 — run shape route reconciliation.** Must ensure the `workflow_runs` shape surfaces a column the client can correlate to the dispatching user message. Concretely: either expose `trigger_message_id` (already a service-layer field per `DispatchAgentRunInput`) on the row, or document the join path. Ticket 0111 should pin this in its own spec.
- **0124 — remote data wiring (client side).** The client's "send a message" affordance maps to a single `POST .../messages` request; it must NOT also call a separate dispatch route. Ticket 0124 should reference this doc in its client-contract section.
- **0115 — agent_messages production shape.** Must account for the "appended but dispatch-failed" edge case: messages of `role=user` may exist in the shape before any `workflow_runs` row ever appears, and if dispatch errors permanently there may be no run at all. The shape definition itself doesn't change, but the UI states the client renders against the shape do.

## Self-check vs. independent-validation clause

Ticket 0108's validation clause says a reviewer verifies that the client-contract section of this document matches `agent_sessions.go:280`'s current behavior. Direct comparison:

| Doc claim | Code evidence |
|---|---|
| Posting `role=user` dispatches a run; other roles do not | `agent_sessions.go:280` — `if role == "user" { …DispatchAgentRun… }` |
| The message is persisted before dispatch | `agent_sessions.go:269` `AppendMessage` precedes `:281` `DispatchAgentRun` |
| Dispatch error fails the HTTP request | `agent_sessions.go:289–292` `writeRouteError(w, dispatchErr); return` |
| No `workflow_run_id` in the 201 response | `agent_sessions.go:295` returns `msg` (the `AgentMessageResponse`), not the dispatch result |
| Response is `201 Created` | `agent_sessions.go:295` `pkgerrors.WriteJSON(w, http.StatusCreated, msg)` |

All five match. Decision is consistent with current code.
