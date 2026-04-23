# Plue: SSH host-key verification for sandbox terminal

## Context

The remote-terminal path is currently authenticated but not host-authenticated. `plue/internal/routes/workspace_terminal.go:274-281` dials the workspace SSH gateway with `gossh.InsecureIgnoreHostKey()`, so a TLS-terminating API caller can still be tricked into opening a shell against a MITM SSH host. The trust anchor is also already in the right place to fix this cleanly: `plue/internal/services/workspace_ssh.go:93-120` mints per-connection SSH credentials and returns `WorkspaceSSHConnectionInfo`, while the actual SSH host key lives on JJHub's shared SSH gateway (`plue/internal/ssh/server.go:109-115, 831-871`), not on each sandbox VM.

This matters more for iOS than for today's browser UI. The main spec makes remote terminal a first-class mobile feature, and mobile clients do not have an operator-managed `known_hosts` file to fall back to.

## Goal

Replace `InsecureIgnoreHostKey()` with real host-key verification for workspace terminal connects, using a trust anchor delivered by plue's authenticated workspace-credential minting flow.

## Proposed design

- **Chosen strategy:** authenticated API-distributed host-key pinning, not TOFU.
  - Extend `services.WorkspaceSSHConnectionInfo` (`plue/internal/services/workspace.go:74-85`) with SSH host-key material for the JJHub gateway, for example:
    - `host_keys`: array of `{algorithm, public_key, fingerprint_sha256}`.
    - Optional `known_hosts_lines` if we want OpenSSH-compatible formatting for non-Go clients too.
  - Populate that material in `buildWorkspaceSSHConnectionInfo` (`plue/internal/services/workspace_ssh.go:93-120`) from the gateway host key(s) JJHub actually serves.
  - Have `WorkspaceTerminalHandler.dialSSH` (`plue/internal/routes/workspace_terminal.go:268-301`) build a strict `HostKeyCallback` from those pinned keys and reject mismatches before shell startup.
- **Why not TOFU:** the SSH endpoint is a shared JJHub gateway host (`workspace_ssh.go:110-119` returns `s.sshHost`), so TOFU would trust the first MITM forever and still leaves fresh mobile installs exposed.
- **Why not SSH CA right now:** the current implementation loads one concrete host key from `ssh_host_ed25519_key` (`internal/ssh/server.go:109-115, 831-871`). A CA could be a follow-up if JJHub needs multiple SSH frontends; it is extra operational machinery for a single-gateway topology.
- **Rotation requirement:** support at least two valid host keys during rotation. The credential response should be able to return the current key and a next key so clients can verify either during a rollout.

## Scope

- **In scope**
  - Add gateway host-key material to `WorkspaceSSHConnectionInfo`, which already carries the minted access token and host metadata.
  - Thread that data through both SSH-info JSON routes:
    - `GET /api/repos/{owner}/{repo}/workspaces/{id}/ssh` in `plue/internal/routes/workspace.go:163-190`.
    - `GET /api/repos/{owner}/{repo}/workspace/sessions/{id}/ssh` in `plue/internal/routes/workspace.go:583-610`.
  - Replace `gossh.InsecureIgnoreHostKey()` in `workspace_terminal.go` with a verifier that accepts only advertised keys for `info.Host:info.Port`.
  - Surface fingerprint data in error logs so host-key mismatch reports are actionable.
  - Document the operational runbook for rotating `ssh_host_ed25519_key` from `cfg.SSH.HostKeyDir` (`plue/cmd/ssh/main.go:158-166`).
- **Out of scope**
  - Moving terminal transport away from SSH.
  - Per-sandbox host keys. The current SSH topology is a shared gateway keyed by VM ID in the username, not one SSH daemon per VM.
  - SSH certificate authorities unless the design review concludes the gateway is about to become multi-front-end.

## References

- `plue/internal/routes/workspace_terminal.go:153-159` — terminal shell startup depends on a successful SSH dial.
- `plue/internal/routes/workspace_terminal.go:274-281` — current insecure host-key callback.
- `plue/internal/services/workspace_ssh.go:93-120` — existing SSH credential minting path to extend.
- `plue/internal/services/workspace.go:74-85` — `WorkspaceSSHConnectionInfo` shape today.
- `plue/internal/routes/workspace.go:163-190` — workspace-level SSH info route.
- `plue/internal/routes/workspace.go:583-610` — session-level SSH info route.
- `plue/internal/ssh/server.go:109-115` — gateway SSH server loads concrete host key(s).
- `plue/internal/ssh/server.go:831-871` — host key is generated/read from `ssh_host_ed25519_key`.
- `plue/cmd/ssh/main.go:158-166` — SSH server config includes `HostKeyDir`.

## Acceptance criteria

- `workspace_terminal.go` no longer uses `gossh.InsecureIgnoreHostKey()` or any equivalent bypass in the workspace-terminal path.
- `WorkspaceSSHConnectionInfo` includes sufficient host-key material for clients to verify the JJHub SSH gateway before authentication completes.
- Terminal connect succeeds when the advertised host key matches and fails closed when the host key is missing, wrong, or for a different host.
- Rotation is supported: the verifier accepts any advertised key in the response, and a test covers overlap of old+new keys.
- Route/service tests verify both `/workspaces/{id}/ssh` and `/workspace/sessions/{id}/ssh` include the new host-key fields.
- Integration test uses a real Go SSH test server and proves:
  - correct key -> shell starts.
  - mismatched key -> connection rejected before PTY allocation.
- Operational docs describe how to rotate the gateway host key without breaking existing clients.

## Independent validation

See 0099. Until 0099 lands: reviewer greps the terminal path for `InsecureIgnoreHostKey`, confirms the negative test uses a real mismatched SSH host key rather than a stubbed callback, and checks that the advertised trust anchor comes from JJHub's authenticated SSH-info minting path instead of a hard-coded client constant.

## Risks / unknowns

- If JJHub later serves SSH from multiple frontends, a single pinned key may become awkward. The ticket should leave room for an array of keys so a later CA migration is additive.
- Returning the raw public key is preferable to returning only a fingerprint; fingerprints are better for diagnostics than for actual verification.
- The `/ssh` routes may already be used by external tooling. Extending the JSON response is safe, but any shape change should be documented.
