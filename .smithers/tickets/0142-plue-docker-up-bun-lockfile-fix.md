# Plue: fix `make docker-up` bun lockfile drift

## Context

Discovered during ticket 0094 (H-POC-WS-PTY). `make docker-up` in
`/Users/williamcory/plue` fails at the `apps/workflow-runtime`
Dockerfile step because `bun install --frozen-lockfile` exits 1 —
`bun.lock` has drifted from `package.json`. This blocks every live
integration test that needs the plue stack.

## Goal

Re-sync the lockfile so `make docker-up` succeeds cleanly.

## Scope

- `apps/workflow-runtime/bun.lock` — refresh via `bun install`.
- `apps/workflow-runtime/package.json` — only if the drift requires a
  version bump.
- DO NOT weaken the Dockerfile by dropping `--frozen-lockfile`.

## Acceptance criteria

- `cd /Users/williamcory/plue && make docker-up` completes cleanly.
- All services report healthy in `docker ps`.
- `make docker-down` tears down cleanly.
- Same lockfile works for both bun install and the frozen-lockfile
  enforcement in the Dockerfile.
