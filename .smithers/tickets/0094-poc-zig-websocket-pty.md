# PoC: Zig WebSocket PTY client

## Context

From `.smithers/specs/ios-and-remote-sandboxes-execution.md`, PoC-A3. Stage 0 foundation. Terminal byte streams are the second major network surface on the client (alongside Electric shapes). This PoC proves Zig can drive plue's existing WebSocket terminal endpoint.

## Problem

Plue already speaks a WebSocket PTY protocol at `GET /api/repos/{owner}/{repo}/workspace/sessions/{id}/terminal` (see `plue/internal/routes/workspace_terminal.go`). The protocol is: binary frames for PTY bytes, text frames with a resize JSON message. We need a Zig client that speaks it, since the Swift UI never touches the wire itself — `libsmithers-core` owns the connection and feeds bytes into libghostty.

## Goal

A minimal Zig library that connects to plue's terminal WebSocket, handles binary/text frame dispatch, writes input, and reads output — proven by integration tests against a running plue instance.

## Scope

- **In scope**
  - Zig library at `poc/zig-ws-pty/`.
  - WebSocket client (TLS + HTTP/1.1 upgrade + RFC-6455 framing). Build on a Zig WS library if one is usable; otherwise the PoC includes a thin WS implementation scoped to client-only.
  - **Handshake requirements:**
    - **Origin (enforced by plue):** `workspace_terminal.go:84` checks `Origin` against the handler's `AllowedOrigins` list and rejects mismatches. Client must send a valid Origin; a negative test with a bad Origin must confirm plue's rejection.
    - **Subprotocol (client sends, not rejected by plue):** plue offers `Subprotocols: []string{"terminal"}` via `websocket.Accept` at `workspace_terminal.go:141`. The `coder/websocket` library selects a matching subprotocol when the client offers one but does NOT reject missing/invalid subprotocols (see `coder/websocket/accept.go:141`). So the client sends `Sec-WebSocket-Protocol: terminal` as a correctness practice, but we do NOT test plue for rejection of wrong/missing subprotocols — that rejection does not exist. If we want it enforced, it's a plue change, not a client test.
  - Bearer token in `Authorization` header.
  - Binary frames for bytes; text frames for JSON control messages (resize).
  - Graceful close; abrupt disconnect detection.
  - Integration test spawns a plue dev server + test sandbox, connects, runs `echo hello`, asserts `hello\n` arrives over the binary frames.
  - Unit tests for frame encode/decode happy paths and edge cases (fragmented frames, close codes, ping/pong).
- **Out of scope**
  - libghostty integration (combined in PoC-A5).
  - Input handling / keybindings — this PoC writes raw bytes only.
  - Multi-client attach (separate PoC, B4).
  - **Reattach-to-live-session.** Plue today does not support reattaching a second WebSocket to an existing SSH session; the PoC's reconnect test acceptance is "detect close cleanly, establish a **fresh** connection," not "resume the prior terminal state." Session-survive-reconnect is the domain of PoC-B4.

## References

- `plue/internal/routes/workspace_terminal.go:83–268` — reference server.
- `github.com/coder/websocket` — the WS library plue uses; wire format reference.
- `karlseguin/websocket.zig` — candidate Zig WS library; evaluate before writing our own.

## Acceptance criteria

- Zig client connects to plue (with correct Origin header + `terminal` subprotocol + bearer token), sends the resize message, writes `echo hello\n`, reads back `hello\n` in the output stream. Test passes green.
- Handshake negative test: **bad Origin** is rejected by plue; client reports the rejection as a distinct error. (No negative test for missing/invalid subprotocol — plue does not reject these today.)
- Reconnect path: connection dies mid-stream, client reports the close cleanly, caller can establish a **fresh** connection (not session resume). Test covers both server-initiated and network-simulated drops.
- Ping/pong keepalive handled transparently at the protocol layer; verified via unit test on frame decode, not a wall-clock 30s integration test.
- README covers: how to spin up plue with a test sandbox, how to run the integration test, the exact Origin/subprotocol/token values sent, and the message shapes exchanged.

## Independent validation

See D3 (`ticket 0099`). Until D3 lands: reviewer verifies the test actually hits a real PTY in a real sandbox (not a mock), and that frame boundaries are tested (a long output spanning multiple frames is reassembled correctly).

## Risks / unknowns

- WS library choice: `karlseguin/websocket.zig` looks active but may be server-biased; client support may need work.
- TLS: plue in dev uses self-signed; the Zig HTTP/WS client needs a path to accept a configured root, not just system CA roots.
