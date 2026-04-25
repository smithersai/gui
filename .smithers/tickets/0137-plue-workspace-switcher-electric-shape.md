# Plue: workspace switcher Electric shape

## Status: CLOSED — superseded by 0116

The parallel production-shapes planning pass produced ticket **0116** (`plue/internal/.../workspaces production shape`), which already covers the switcher's subscription needs with the `where` clause template `repository_id IN (<repo_ids>) AND user_id = <authed_user_id>` (see `.smithers/specs/ios-and-remote-sandboxes-production-shapes.md:14`). This ticket was written before 0116 landed, under the explicit condition "close as duplicate if the production-shapes pass covers it." It does.

## What to read instead

- **0116** — `plue-workspaces-production-shape.md` owns the shape.
- **0135** — `plue-global-cross-repo-workspace-listing.md` now additionally owns the **repo-discovery** surface the switcher needs (`/api/user/readable-repos` or equivalent) so the client knows which `repository_id` values to include in the shape filter. See 0135's updated scope.
- **0138** — `client-workspace-switcher-recent-first.md` consumes 0116 (via 0135's repo-discovery list) plus 0135/0136 for the REST+recency path.

## Why this is a tombstone, not a deletion

Keeping the number reserved with an explanation prevents future readers from hitting "where did 0137 go?" and avoids accidental reuse. No work is owned here.
