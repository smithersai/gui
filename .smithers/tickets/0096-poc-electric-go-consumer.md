# PoC: ElectricSQL Go consumer against plue's auth proxy

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, PoC-B1. Stage 0 foundation. Plue already has `cmd/electric-proxy/` + `internal/electric/` for shape auth. It has zero Go-side consumers and zero Go-side tests today. This PoC makes us the first real consumer and adds coverage.

## Problem

Before anyone writes serious Electric client code in any language, we need:

1. Proof the Go proxy actually works end-to-end against a running upstream Electric service (no one has done this in a test).
2. A reference Go consumer that PoC-A2 (Zig client) and PoC-B3 (approvals) can both study. Note: this is a **reference/harness**, not a prerequisite — PoC-A2 can run in parallel.
3. Go tests inside `internal/electric/` for the auth path.

## Goal

A working Go client in `plue/poc/electric-go-consumer/` that subscribes to shapes through the proxy with a real auth token, plus `*_test.go` coverage inside `internal/electric/`.

## Scope

- **In scope**
  - `plue/poc/electric-go-consumer/` — a runnable Go binary that connects to the proxy, subscribes to a synthetic `poc_items` shape (filtered by `repository_id IN (...)` to satisfy plue's auth check), prints incoming deltas.
  - Docker-compose fragment spins up plue + Postgres + upstream `electric:3000` service. Lives in the PoC directory; a follow-up ticket (tracked separately, not this one) promotes it to plue's canonical `docker-compose.yml` if appropriate.
  - **Write path:** for this PoC, writes happen directly to Postgres via test fixtures or a temporary throwaway handler — not via plue's production REST routes. Reason: the production write surface for `poc_items` doesn't exist; inventing one for the PoC is scope creep. The Zig client PoC (A2) tests reads; writes-through-REST are tested separately once real shapes exist (Stage 1).
  - `internal/electric/*_test.go` — unit tests covering: valid bearer token accepted, invalid rejected, wrong-repo where-clause rejected, upstream unavailable returns 502.
  - Integration test: insert via fixture + subscribe via consumer + observe delta, end-to-end.
- **Out of scope**
  - Zig client (PoC-A2; parallel).
  - Production shape definitions for agent_sessions/runs/etc.
  - Desktop-local engine (separate spec).
  - Promoting the compose fragment into plue's canonical docker-compose.yml — follow-up ticket.

## References

- `plue/internal/electric/proxy.go`, `auth.go` — what we're testing.
- `plue/cmd/electric-proxy/main.go` — the binary we're fronting.
- `plue/oss/packages/sdk/src/services/sync.ts` — TS client pattern; translate to Go.
- `@electric-sql/client` — protocol semantics source of truth.

## Acceptance criteria

- `docker-compose up` brings up the full stack locally with one command.
- `go run ./poc/electric-go-consumer/` attaches, subscribes, and prints live deltas as rows change.
- `go test ./internal/electric/...` passes with meaningful coverage: auth pass/fail paths, where-clause scope enforcement, upstream failure fallback.
- Integration test asserts writer-to-subscriber delta fan-out.
- README documents the compose setup and test invocation.

## Independent validation

See D3 (`ticket 0099`). Until D3 lands: reviewer verifies the upstream Electric service is actually running in the stack (not stubbed), auth rejection tests use a bad-but-well-formed token (not `""`), and the integration test runs in CI in under a reasonable timeout.

## Risks / unknowns

- Upstream Electric version compatibility with plue's Postgres version.
- Where-clause parser in `auth.go` may not cover every shape we want; the PoC may surface parser gaps that become follow-up tickets.
