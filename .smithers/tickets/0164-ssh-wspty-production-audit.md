# SSH + WebSocket PTY production audit

Audited on 2026-04-24 against `/Users/williamcory/plue` plus the GUI client code under `libsmithers/src/core/wspty`.

## Severity counts

- Critical: 1
- High: 3
- Medium: 6
- Low: 0

## Scope notes

- `pkg/ssh/` does not exist.
- `cmd/ssh/ssh` is a checked-in Mach-O executable, not source.
- The explicit `cmd/ssh/` source is SSH server bootstrap. The production SSH client paths needed to evaluate ticket 0130 live in `internal/routes/workspace_terminal.go`, `internal/services/workspace_ssh.go`, and the workspace CLI paths, so those are included where directly relevant.
- Origin validation is now present and exact-match scoped to `email.base_url`'s origin; I did not file a finding for origin validation itself.
- I did not find a separate command-injection bug in the WS frame parser. Binary frames are intentionally raw PTY input and text frames are JSON resize controls. The security boundary is the authenticated, sandboxed workspace VM, so the remaining risk is mostly from host-key bypass, auth/protocol gating, and session isolation.

## Findings

### Critical: workspace terminal SSH still disables host-key verification

Evidence:
- `internal/routes/workspace_terminal.go:274-281` builds `gossh.ClientConfig` with `HostKeyCallback: gossh.InsecureIgnoreHostKey()`.
- `internal/services/workspace.go:77-87` defines `WorkspaceSSHConnectionInfo` with host, user, token, and command fields, but no host-key or known-hosts material.
- `internal/services/workspace_ssh.go:110-119` returns the SSH command/access token without any gateway public key or fingerprint.

Impact:
- This fails ticket 0130's primary acceptance criteria. The API server can authenticate the user and still open the terminal against a MITM or misrouted SSH gateway before PTY allocation.
- Because the access token is sent as SSH password auth, a successful MITM can capture a live workspace credential.

Fix:
- Extend `WorkspaceSSHConnectionInfo` with gateway host-key material, preferably an array of `{ algorithm, public_key, fingerprint_sha256 }` plus optional OpenSSH `known_hosts` lines.
- Populate that material from the actual SSH gateway key loaded from `cfg.SSH.HostKeyDir`.
- Replace `InsecureIgnoreHostKey()` with a callback that accepts only the advertised keys for `info.Host:info.Port`, supports at least two keys for rotation, and fails closed on missing/mismatched keys.
- Add integration tests with a real Go SSH server for correct-key success and mismatched-key rejection before `RequestPty`.

### High: libsmithers WS PTY client connects to a route plue does not register

Evidence:
- GUI RealTransport builds the terminal URL as `/api/workspace/sessions/{session_id}/terminal` in `/Users/williamcory/gui/libsmithers/src/core/transport.zig:706-719`.
- Plue registers only `/api/repos/{owner}/{repo}/workspace/sessions/{id}/terminal` in `cmd/server/main.go:1000-1018`.
- The wspty handshake comment already names the repo-scoped path in `/Users/williamcory/gui/libsmithers/src/core/wspty/handshake.zig:18`.

Impact:
- The promoted native GUI WS PTY path cannot attach to the production plue route as written. It will handshake against an unregistered API path and fail before any PTY behavior can be evaluated.

Fix:
- Carry `owner` and `repo` into the RealTransport PTY attach path, or return a terminal URL from the plue session/workspace API and use it directly.
- Add a client integration test that asserts the exact path used by libsmithers matches the plue route shape.

### High: `terminal` subprotocol and bearer-only WS auth are not enforced

Evidence:
- `internal/routes/workspace_terminal.go:141-144` advertises `Subprotocols: []string{"terminal"}` to `websocket.Accept`, but the handler never rejects requests that omit `Sec-WebSocket-Protocol: terminal` and never checks `wsConn.Subprotocol()`.
- The first-party web UI opens `new WebSocket(wsUrl)` without a subprotocol in `apps/ui/src/components/Terminal.tsx:117-122`, which confirms the server currently accepts non-`terminal` clients.
- The terminal route uses generic `AuthLoader`/`RequireAuth`/`RequireScope` middleware in `cmd/server/main.go:1003-1018`, not a terminal-specific bearer requirement.
- The GUI wspty client sends `Origin`, `Sec-WebSocket-Protocol`, and `Authorization` in `/Users/williamcory/gui/libsmithers/src/core/wspty/handshake.zig:39-44`, but it does not verify that the response selected `terminal`; `performHandshake` only checks `Sec-WebSocket-Accept` in `/Users/williamcory/gui/libsmithers/src/core/wspty/client.zig:132-142`.

Impact:
- This fails the checklist item requiring `Sec-WebSocket-Protocol: terminal` plus bearer validation.
- Cookie-authenticated browser clients can still connect without the terminal subprotocol. Origin validation reduces CSRF exposure, but the terminal handshake is not explicitly bound to the expected protocol or bearer transport.

Fix:
- Before accepting, parse `Sec-WebSocket-Protocol` and reject if `terminal` is absent.
- After accepting, verify `wsConn.Subprotocol() == "terminal"`.
- Decide whether browser cookie auth is intentionally supported. If the production contract is bearer-only, require `Authorization: Bearer ...` for this route and reject cookie-only authentication.
- Update `apps/ui/src/components/Terminal.tsx` to pass `"terminal"` and update the Zig client to require `parsed.subprotocol == "terminal"`.

### High: WS-to-client backpressure can block terminal goroutines indefinitely

Evidence:
- `internal/routes/workspace_terminal.go:203-204` creates a request-scoped context with no write deadline.
- `internal/routes/workspace_terminal.go:304-311` reads SSH output and calls `ws.Write(ctx, websocket.MessageBinary, buf[:n])` directly.
- There is no bounded outbound queue, no per-write timeout, no byte-drop policy, and no session close on slow reader.

Impact:
- If a client stops reading while keeping the TCP/WebSocket connection open, SSH output writes can block until the request context is canceled.
- That can pin goroutines and stop draining the SSH session, producing a resource-exhaustion path for terminal sessions.

Fix:
- Put SSH output into a bounded per-connection queue.
- Use a short per-write context/deadline for each WebSocket write.
- On queue overflow or repeated write timeout, close the WebSocket and SSH session with an explicit slow-consumer reason.
- Add a regression test with a client that stops reading while the PTY emits output.

### Medium: idle cleanup marks DB state but does not control live WS/SSH sessions

Evidence:
- Session activity is touched on session creation in `internal/services/workspace_exec.go:99-108` and SSH-info fetch in `internal/services/workspace_ssh.go:80-88`.
- Terminal I/O paths do not touch activity; `pipeWSToSSH` writes input to SSH in `internal/routes/workspace_terminal.go:329-367` without updating session activity.
- Cleanup finds idle DB rows in `internal/services/workspace_lifecycle.go:122-135`, then calls `DestroySession`.
- `DestroySession` marks the DB row stopped and may suspend the workspace in `internal/services/workspace_exec.go:176-195`, but there is no active WebSocket/SSH session registry to close the handler.

Impact:
- A live interactive terminal can be considered idle because reads/writes do not refresh `last_activity_at`.
- A dead or slow client is eventually changed in DB, but the active handler is not directly GCed unless SSH/WebSocket operations fail as a side effect.

Fix:
- Track active terminal connections by session ID and close them when idle cleanup destroys a session.
- Refresh session/workspace activity on accepted terminal input and optionally on output.
- Add tests proving idle cleanup closes an active WS/SSH handler and that regular terminal input prevents idle cleanup.

### Medium: multi-client attach is not implemented; duplicate attaches create independent shells

Evidence:
- Every WebSocket attach calls `h.dialSSH(...)` in `internal/routes/workspace_terminal.go:153-154`.
- Each attach then creates a new SSH session, requests a new PTY, and starts a new shell in `internal/routes/workspace_terminal.go:163-201`.
- There is no session-ID keyed PTY registry, fanout buffer, scrollback store, or attach policy in the handler.

Impact:
- Two clients connecting to the same workspace session do not see the same terminal. They get independent shells with independent PTY state.
- This avoids shared input leakage, but it fails the multi-client attach semantics ticket 0102 was meant to evaluate or ship.

Fix:
- Introduce one PTY owner per workspace session and let each WebSocket attach as a viewer/writer against that owner.
- Give each client its own outbound cursor/scrollback replay.
- Define and test write policy for simultaneous input.
- Test detach-one-client while the other remains attached.

### Medium: runner `workspace-pty.ts` is not wired to the plue internal API it expects

Evidence:
- `cmd/runner/workflow/workspace-pty.ts:68-81` posts PTY output to `/internal/workspace/sessions/{sessionId}/output`.
- `cmd/runner/workflow/workspace-pty.ts:114-125` polls `/internal/workspace/sessions/{sessionId}/input`.
- `cmd/runner/workflow/workspace-pty.ts:237-248` expects `GET /internal/workspace/{workspaceId}` to return pending sessions.
- Plue only registers `POST /internal/workspace/{id}/status` for workspace internals in `cmd/server/main.go:720-752` and `internal/routes/workspace_internal.go:28-60`.

Impact:
- This runner PTY implementation cannot drive terminal input/output against the current server. It appears to be dead or half-migrated relative to the direct SSH WebSocket handler.

Fix:
- Either remove this runner PTY path from the production stack or implement the internal workspace/session input/output routes it expects.
- If retained, add end-to-end tests from session creation through runner PTY spawn, input delivery, output persistence/streaming, and session teardown.

### Medium: workspace CLI SSH still uses TOFU/raw SSH rather than authenticated host-key pinning

Evidence:
- `apps/cli/src/commands/workspace.ts:543-556` injects `StrictHostKeyChecking=accept-new` and `UserKnownHostsFile=...`, which is TOFU, not API-pinned host-key verification.
- `apps/cli/src/agent/backends/workspace.ts:355-367` uses the server-provided SSH command or `ssh_host` directly and does not add a known-hosts file or strict checking.
- No audited production path contains `ProxyJump` handling or a way to pin both a jump host and final gateway host.

Impact:
- Fresh CLI installs can trust the first host key they see, including a first-connect MITM.
- Workspace agent SSH commands can bypass even the TOFU known-hosts file path.
- ProxyJump pinning is not preserved because it is not implemented; if future config introduces a jump host, both hop and target verification need explicit handling.

Fix:
- Return OpenSSH-compatible `known_hosts` lines from `/ssh` API responses.
- Write those lines to an owner-only known-hosts file and connect with `StrictHostKeyChecking=yes`, not `accept-new`.
- Apply the same SSH argument hardening in the workspace agent backend.
- If ProxyJump is supported, pin the jump host and target host separately, or reject ProxyJump until the pinning model is explicit.

### Medium: SSH agent forwarding is not explicitly disabled

Evidence:
- `apps/cli/src/commands/workspace.ts:543-556` injects SSH options, but not `ForwardAgent=no`, `IdentityAgent=none`, or equivalent.
- `apps/cli/src/agent/backends/workspace.ts:355-367` returns raw SSH args with no agent-forwarding guard.

Impact:
- OpenSSH defaults usually disable agent forwarding, but user SSH config or server-provided options can still enable it. Production workspace commands should not rely on defaults for a sandbox boundary.

Fix:
- Add explicit `-o ForwardAgent=no` and consider `-o IdentityAgent=none` for workspace SSH invocations.
- Add tests that a user config enabling `ForwardAgent yes` is overridden by the generated command.

### Medium: SSH gateway private key is permissioned but not encrypted at rest

Evidence:
- `internal/ssh/server.go:844-864` generates an Ed25519 private host key, writes an unencrypted PEM block, and sets file mode `0600`.
- `internal/ssh/server.go:845` creates the key directory with `0700`.
- Existing-key loading in `internal/ssh/server.go:831-839` reads whatever key is present without checking file mode or encrypted-at-rest provenance.

Impact:
- The file permission requirement is met for generated keys, but the private key is not encrypted at rest.
- If ticket 0130's production bar includes encrypted private-key storage, this remains incomplete.

Fix:
- Load the gateway host key from Secret Manager/KMS or an encrypted local key store with a runtime decrypt step.
- Enforce mode checks on existing key files and fail startup on group/world-readable key material.
- Document rotation and storage requirements alongside the host-key pinning change.

## Checklist result

- SSH host-key verification: fail. The Go terminal path uses `InsecureIgnoreHostKey`; CLI uses TOFU or raw SSH.
- Private keys at rest: partial. Generated host key uses `0700` directory and `0600` file, but unencrypted PEM and no existing-file mode check.
- ProxyJump pinning: fail/not implemented. No production ProxyJump model or hop pinning.
- SSH agent forwarding disabled: partial. Default OpenSSH behavior helps, but generated commands do not explicitly disable it.
- Origin validation: pass for current server path. Empty/null origins and origins outside `apiAllowedOrigins` are rejected.
- `Sec-WebSocket-Protocol` and bearer: fail. `terminal` is not required and bearer-only auth is not enforced.
- Idle timeout/GC: partial. DB cleanup exists, but live WS/SSH handlers are not directly closed and terminal I/O does not refresh activity.
- Backpressure: fail. Direct blocking writes with no bounded queue or write timeout.
- Command injection via WS frames: no distinct finding. Raw PTY input is intended and goes to the sandbox VM.
- Multi-client attach: fail. Duplicate attaches create separate shells, not shared PTY views with independent scrollback.
