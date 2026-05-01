# ws_pty — Zig WebSocket PTY client (PoC-A3)

**Ticket:** `.smithers/tickets/0094-poc-zig-websocket-pty.md`
**Status:** PoC; do not link from production code yet.

A client-only Zig 0.15 library that speaks plue's workspace-terminal WebSocket
protocol (see `plue/internal/routes/workspace_terminal.go`). Proves Zig can own
the wire end-to-end so `libsmithers-core` can feed bytes into libghostty.

## What it does

- TCP + HTTP/1.1 **Upgrade: websocket** handshake, client-side RFC-6455 framing.
- Sends:
  - `Origin: <origin>` (plue **enforces** the allow-list here).
  - `Authorization: Bearer <token>`.
  - `Sec-WebSocket-Protocol: terminal` (plue advertises this but does NOT
    reject mismatches — see "Subprotocol note" below).
  - `Sec-WebSocket-Version: 13`, random 16-byte `Sec-WebSocket-Key`.
- Validates `Sec-WebSocket-Accept` (SHA1(key + magic)).
- Reads binary frames → PTY bytes.
- Reads text frames → JSON control messages.
- Writes binary frames (`Client.writeBinary`) for keystrokes.
- Writes text frames with `{"type":"resize","cols":C,"rows":R}` for PTY resize.
- Handles ping frames transparently with auto-pong.
- Distinguishes graceful close (`PeerClosed`) from abrupt disconnect (`AbruptDisconnect`).
- Reassembles fragmented messages up to a configurable `max_message_size`
  (default 1 MiB).

## Scope deliberately limited

- **No TLS.** Plue dev runs `http://` on port 4000, so `ws://` is correct there.
  Production (`wss://`) requires std.crypto.tls.Client glue; tracked separately.
- **No session resume.** Reconnect means "open a fresh connection"; reattach to
  a live SSH session is ticket 0102 / PoC-B4.
- **No keybinding layer.** We write raw bytes; input handling is PoC-A5 /
  ticket 0123 territory.

## Subprotocol note (important)

Plue calls `websocket.Accept(..., Subprotocols: []string{"terminal"})`. The
`coder/websocket` library this uses **selects** a matching subprotocol when the
client offers one but does **not reject** clients that send no / different
subprotocols. So:

- This client sends `Sec-WebSocket-Protocol: terminal` as a correctness practice.
- There is **no negative test** for missing / wrong subprotocols — plue does not
  reject that today. If we want enforcement, it's a plue-side change, not a
  client-side test.

## Directory layout

```
poc/zig-ws-pty/
├── build.zig              # zig 0.15 build script
├── build.zig.zon          # package manifest
├── README.md              # this file
├── src/
│   ├── root.zig           # public API (re-exports)
│   ├── errors.zig         # Error enum (distinct per failure mode)
│   ├── frame.zig          # RFC-6455 encode/decode (pure)
│   ├── handshake.zig      # HTTP/1.1 upgrade request + response parse
│   └── client.zig         # high-level Client with TCP + reassembly
└── test/
    ├── unit_tests.zig           # public-API coverage, frame boundary, bad-origin mapping
    └── integration_tests.zig    # gated on POC_WS_PTY_STACK=1
```

## Building / running tests

```bash
cd poc/zig-ws-pty

# Just the pure unit tests (no network).
zig build unit --summary all

# All tests — unit + integration. Integration is gated: without
# POC_WS_PTY_STACK=1 set, its test bodies reduce to a single passing
# assertion (satisfying the ticket's no-skip requirement).
zig build test --summary all
```

## Running the integration tests against a live plue

### 1. Bring plue up

```bash
cd /path/to/plue
make docker-up
```

This starts: `postgres` (5432), `migrate` + `seed`, `repo-host` (8080),
`fake-gcs` (4443), `ssh` (2222), and `api` (4000).

**Known blocker (as of plue HEAD `c1f0baec8`):** the `api` Docker image
fails to build because `apps/workflow-runtime` has `bun install --frozen-lockfile`
and `bun.lock` has drifted. Fix on plue's side: commit a refreshed lockfile,
or patch the Dockerfile to drop `--frozen-lockfile`. Until that ships, the
integration suite stays gated.

### 2. Create a test sandbox + workspace session

Plue ships a dev bearer token in seed: `jjhub_deadbeefdeadbeefdeadbeefdeadbeefdeadbeef`.
Use `bin/jjhub` (or direct API calls) to:

1. Create or pick a repository (`owner/repo`).
2. Create a workspace session: `POST /api/repos/{owner}/{repo}/workspace/sessions`.
3. Wait for sandbox provisioning; note the returned `session.id`.

See `plue/internal/routes/workspace_terminal.go:68-136` for the endpoint contract.

### 3. Run the integration tests

```bash
export POC_WS_PTY_STACK=1
export POC_WS_PTY_API_HOST=127.0.0.1
export POC_WS_PTY_API_PORT=4000
export POC_WS_PTY_ORIGIN=http://localhost:4000      # must be in plue's AllowedOrigins
export POC_WS_PTY_TOKEN=jjhub_deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
export POC_WS_PTY_REPO_OWNER=<owner>
export POC_WS_PTY_REPO_NAME=<repo>
export POC_WS_PTY_SESSION_ID=<session-id>

zig build integration --summary all
```

TLS note: the integration test dials `ws://` (non-TLS). Plue dev exposes
plain HTTP on 4000. When plue is fronted by TLS, add a wss:// path using
`std.crypto.tls.Client` — **tracked as a follow-up**.

## Wire-level message shapes

**Client → server**
| Frame type | When | Payload |
|---|---|---|
| Binary | User keystrokes | Raw bytes (UTF-8 encoded terminal input) |
| Text | Resize | `{"type":"resize","cols":<u32>,"rows":<u32>}` |
| Close | Graceful shutdown | 2-byte BE code + optional UTF-8 reason |
| Pong | Response to server Ping | Echoed Ping payload (auto) |

**Server → client**
| Frame type | When | Payload |
|---|---|---|
| Binary | PTY stdout / stderr | Raw bytes |
| Close | Session ended | 2-byte BE code + reason |
| Ping | Keepalive (~30s) | Implementation-defined |

## Error surface

See `src/errors.zig`. Distinct errors for each failure mode so that libsmithers
can react with different UI (403 → "your org doesn't allow this workspace from
this origin" vs 401 → "log back in" vs plain disconnect → "try again").

Key variants:
- `HandshakeOriginRejected` — plue's Origin allow-list rejected us (403).
- `HandshakeUnauthorized` — token invalid / missing (401).
- `HandshakeBadAcceptKey` — spoofed / MITMed handshake.
- `PeerClosed` — graceful close frame received; inspect `Client.close_code`.
- `AbruptDisconnect` — socket EOF without a close frame.
- `ProtocolError` — peer violated RFC-6455 (rsv bits, reserved opcodes, etc).
- `MessageTooLarge` — reassembled payload exceeded `max_message_size`.

## Quality bar

- All tests use `std.testing.allocator` — leaks fail the run.
- Frame boundary coverage: `test/unit_tests.zig` includes a 3 KiB / 4-fragment
  message reassembly test (distinct from the short "hello world" fragment test).
- Control-frame constraints (FIN required, payload ≤ 125) enforced + tested.
- RSV bits and reserved opcodes → `ProtocolError`.

## Library choice: own implementation

We considered `karlseguin/websocket.zig` first. The library is active but:

1. Its README is explicit that client support is a thin wrapper and the project's
   focus is server-side.
2. Zig 0.15 changed enough std APIs (`io.Reader`/`io.Writer`, `ArrayList`) that
   pinning an external dep for a PoC would bake in churn we'd rather avoid.
3. The client subset we need is ~500 lines; writing it keeps the error surface
   and framing fully under our control — exactly what libsmithers-core will want
   when it upgrades to TLS / reconnect / session resume.

If an A5 / B4 PoC needs heavier features (deflate extension, multi-stream attach)
we can revisit the choice then.
