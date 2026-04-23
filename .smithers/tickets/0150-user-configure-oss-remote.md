# User: configure writable oss remote

## Context

Ticket 0144 landed 9 commits to `/Users/williamcory/plue/oss` on local
`main`, reconciling schema + queries with plue tickets 0105, 0114,
0115+0118, 0107, 0110, 0134, 0135+0136 + a github_app_installations
restoration from a recovered stash.

Push to origin **FAILED** — `https://github.com/jjhub-ai/jjhub.git` is
archived (read-only). `smithersai/jjhub` and `codeplaneapp/jjhub`
mirrors also archived. No writable oss remote exists.

## What the user needs to do

Pick one:

### Option A: unarchive jjhub-ai/jjhub
- Go to GitHub repo settings → unarchive.
- Then: `cd /Users/williamcory/plue/oss && git push origin main`.

### Option B: create a new writable mirror
- Create `smithersai/jjhub-oss` (or similar) on GitHub.
- `cd /Users/williamcory/plue/oss && git remote set-url origin git@github.com:smithersai/jjhub-oss.git && git push origin main`.

### Option C: move oss content into plue as a subdirectory
- Flatten `oss/` into `plue/oss/` (drop the separate repo).
- Requires updating `plue/db/sqlc.yaml` schema/query paths if they use
  `../oss/...` relative references.
- Most invasive; only if options A + B are not available.

## Commits waiting locally (as of 0144 completion)

```
1fcda48 chore(db): restore github_app_installations + webhook_jobs tables
6d62df0 feat(db): 0105 — workspaces.deleted_at soft-delete + quota index
584ea11 feat(db): 0114 — agent_sessions.deleted_at tombstone
6e9efea feat(db): 0115+0118 — agent_messages + agent_parts repo/session denorm
81637dc feat(db): 0135+0136 — user workspaces listing + last_accessed_at
8fc54e6 feat(db): 0107 — devtools_snapshots table + queries
da9441c feat(db): 0110 — approvals table + queries
b4bbb47 feat(db): 0134 — audit_log filtered query extension
dff7c2f fix(db): add github_username/github_avatar_url to alpha_waitlist_entries  (landed earlier via 0143)
```

## Acceptance criteria

- oss origin is writable.
- Local oss main pushes clean.
- A fresh `git clone plue && git clone oss && make sqlc && make docker-up`
  reproduces plue main's current behavior.
