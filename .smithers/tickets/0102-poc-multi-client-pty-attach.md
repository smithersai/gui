# PoC: multi-client PTY attach

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, PoC-B4, promoted to Stage 0. The main spec's user-facing promises about "multi-device same-user" depend on the outcome of this PoC. Without proving (or disproving) multi-client PTY viability up front, we risk shipping a UX claim that can't be backed. The spec currently keeps multi-client PTY out of scope for v1, but the architectural decision must be made here, not later.

## Problem

Plue's `workspace_terminal.go` today creates one SSH session per WebSocket connection. `workspace_terminal.go:124` calls `GetSSHConnectionInfo`, which resolves to `buildWorkspaceSSHConnectionInfo` (`internal/services/workspace_ssh.go:93, 105`) — that's where fresh SSH credentials are minted. On WebSocket close (`workspace_terminal.go:124, 203, 251, 324`) the SSH session tears down. A second WebSocket connecting to the same `session_id` opens an **independent parallel shell** — not a second view of the first one, and not a replacement of it. So "iPad connects while Mac is already watching" produces two unrelated shells that diverge immediately. That's neither shared attach nor the usual mental model of "the terminal is a thing both devices look at."

## Goal

Prove — in a PoC — what it takes to let two WebSocket clients share one underlying PTY session, and document the chosen design in the main spec. The PoC is allowed to conclude "it's too expensive for v1" as long as that conclusion is recorded with evidence.

## Scope

- **In scope**
  - PoC at `plue/poc/multi-client-pty/`. Language: Go (matches plue) or TypeScript (acceptable since this proves protocol shape, not language).
  - **Two design options evaluated explicitly:**
    1. **Handler-side multiplexing.** `workspace_terminal.go` tracks active sessions by `session_id`; second WebSocket with same ID attaches as a second reader/writer on the same SSH channel.
    2. **Guest-agent attach mode.** Add `MethodAttachPTY` to the guest-agent protocol (`plue/internal/sandbox/guest/`), let the guest manage PTY lifetime independently of any single client.
  - A written rationale (in the PoC README) for which option is chosen, or why neither is worth v1.
  - Test: two simulated clients attach to one session, both observe the same stdout, write policy (one-writer / both-writers / last-writer-wins) is exercised, clean detach of one client doesn't kill the other.
- **Out of scope**
  - Implementing the chosen design into production plue routes — that's a follow-up ticket that depends on this PoC's conclusion.
  - Authorization policy for second-attacher — inherit whatever the first session's auth was; policy work is separate.
  - Making the non-chosen design compile — one option explored deeply is enough.

## References

- `plue/internal/routes/workspace_terminal.go:83–268` — the current handler.
- `plue/internal/sandbox/guest/handler.go` — the guest-agent protocol handler.
- `plue/cmd/guest-agent/main.go` — the guest-agent entry point.

## Acceptance criteria

- `poc/multi-client-pty/README.md` presents both options, the chosen one with rationale, and the trade-offs of the rejected one.
- Test harness demonstrates two clients attaching to one session with the chosen write policy.
- **Spec + execution plan updated** (via drive-by edits in this ticket) to reflect the conclusion:
  - Main spec's section on multi-device same-user: either "multi-client PTY added to scope, will ship in Stage 2" or "stays out of scope, rationale X."
  - Execution plan's Stage list: if adopted, the follow-up production work gets its own Stage entry; if not adopted, mark the PoC "conclusion: deferred" so future readers don't re-ask.
- **Rollout plan update is soft.** The rollout plan (ticket 0101) is itself a Stage 0 design task and may not exist yet when this PoC lands. If 0101 is already merged, update it with the feature-flag decision (add `multi_client_pty_enabled` as a plue prerequisite, or explicitly exclude it). If 0101 hasn't landed yet, leave a note in the PoC README for 0101's author to pick up.

## Independent validation

See 0099. Until 0099 lands: reviewer verifies the second client's attach is tested against a real PTY (not a stub) and that the "detach one, other survives" test actually kills one WebSocket mid-stream.

## Risks / unknowns

- SSH sessions are not natively multi-writer. Handler-side option may need a fan-out buffer and a write-arbitration policy.
- Guest-agent option means new protocol methods, schema change, version compatibility concern.
