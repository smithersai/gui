# Plue/oss: batch-commit accumulated submodule schema + query changes

## Context

Multiple plue tickets (0105, 0114, 0115, 0116, 0117, 0118, 0135, 0136,
0110, 0107, 0134) added schema + queries to `/Users/williamcory/plue/oss/`
as a sibling working tree. Those changes are in the oss filesystem but
have never been committed in the oss git repo. A fresh clone of
plue+oss would not reproduce the plue main state.

Additionally, the 0114 subagent left a `git stash@{0}` in oss/ with
prior unrelated user state — needs resolution.

## Goal

Reconcile the oss working tree: commit intentional additions, restore
the stashed user work, push to oss origin.

## Scope

- Inventory the oss unstaged changes:
  ```
  cd /Users/williamcory/plue/oss
  git status
  git diff --stat
  ```
- Group by ticket (file-level). Create one commit per ticket with a
  clear message matching the plue commit it pairs with.
- Pop `git stash@{0}` and resolve any conflicts with the newly-committed
  state — this is user-authored work that needs preservation.
- Push oss to its origin after 0143 (sqlc drift fix) also lands so
  the schema + queries are self-consistent.

## Acceptance criteria

- `cd /Users/williamcory/plue/oss && git status` shows clean working
  tree + empty stash.
- `git log --oneline -20` shows per-ticket commits authored today.
- plue still builds from a clean checkout of plue + oss together.
- Co-ordinated push with 0143's fix so origin never sees a broken-
  sqlc state.
