# iOS And Remote Sandboxes — Production Shapes

This note tracks the production Electric shapes for remote-mode engine state. It complements `.smithers/specs/ios-and-remote-sandboxes.md` and the backend work in `plue`.

All shapes depend on the Electric proxy from ticket [0096](../tickets/0096-poc-electric-go-consumer.md). Today that proxy only authorizes shapes that include `repository_id IN (...)` in the `where` clause (`/Users/williamcory/plue/internal/electric/auth.go:47-50`, `85-100`, `250-282`).

## Shape set

| Table | Where-clause template | Notes | Ticket |
|---|---|---|---|
| `agent_sessions` | `repository_id IN (<repo_ids>)` | Repo-readable to match the current HTTP/API surface. Needs a synced delete tombstone. | [0114](../tickets/0114-plue-agent-sessions-production-shape.md) |
| `agent_messages` | `repository_id IN (<repo_ids>) AND session_id IN (<open_session_ids>)` | Needs denormalized `repository_id`. Open-chat only; do not subscribe repo-wide. | [0115](../tickets/0115-plue-agent-messages-production-shape.md) |
| `agent_parts` | `repository_id IN (<repo_ids>) AND session_id IN (<open_session_ids>)` | Required because message content lives here. Needs denormalized `repository_id` and `session_id`. | [0118](../tickets/0118-plue-agent-parts-production-shape.md) |
| `workspaces` | `repository_id IN (<repo_ids>) AND user_id = <authed_user_id>` | Current plue behavior is user-private. Requires Electric auth to enforce the `user_id` predicate, not just trust it. | [0116](../tickets/0116-plue-workspaces-production-shape.md) |
| `workspace_sessions` | `repository_id IN (<repo_ids>) AND user_id = <authed_user_id>` | Current row is not shape-safe because `ssh_connection_info` persists minted credentials. 0117 owns redaction/split before sync. | [0117](../tickets/0117-plue-workspace-sessions-production-shape.md) |
| `devtools_snapshots` | `repository_id IN (<repo_ids>) AND session_id IN (<session_ids>)` | Existing ticket. Exact table name is already the proposed production table. | [0107](../tickets/0107-plue-devtools-snapshot-surface.md) |
| `approvals` | `repository_id IN (<repo_ids>)` | Existing ticket. If approvals become user-private later, auth rules must tighten with the route contract. | [0110](../tickets/0110-plue-approvals-implementation.md) |
| `workflow_runs` | `repository_id IN (<repo_ids>)` | Existing ticket 0111 calls this “runs”; the real plue table is `workflow_runs`. | [0111](../tickets/0111-plue-run-shape-route-reconciliation.md) |

## Notes

- `agent_messages` and `agent_parts` cannot ship as shapes on the current schema because the Electric proxy requires a `repository_id` predicate and neither table stores that column today.
- `workspaces` and `workspace_sessions` are user-private in current plue queries/routes. Repo-only Electric auth is insufficient for those tables; production rollout needs a table-aware `user_id = authed.User.ID` check.
- `workspace_sessions.ssh_connection_info` currently stores a minted SSH access token and a fully formed command (`/Users/williamcory/plue/internal/services/workspace_ssh.go:64-79`, `93-120`). That data must not be replicated into client SQLite.
- Workspace delete semantics are still being settled by [0105](../tickets/0105-plue-sandbox-quota-enforcement.md). Do not enable the `workspaces` shape against the current ambiguous “stopped but not deleted” behavior.
