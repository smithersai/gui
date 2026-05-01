# zig-electric-client — PoC Electric shape client in Zig

Ticket 0093. Proves that libsmithers-core (Zig) can subscribe to plue's
ElectricSQL shape proxy, apply rows to a bounded local SQLite, and
survive disconnect/reconnect without gaps or duplicates.

## Layout

```
src/
  root.zig         # public API re-exports
  errors.zig       # distinct Error set
  http.zig         # minimal HTTP/1.1 client (chunked + content-length)
  message.zig      # Electric shape JSON parser (insert/update/delete/control)
  persistence.zig  # SQLite cursor + poc_items store
  client.zig       # state machine: snapshot -> long-poll -> resume
test/
  unit_tests.zig        # Tier 1 — fake in-process HTTP server
  integration_tests.zig # Tier 2 — real stack (gated on POC_ELECTRIC_STACK=1)
build.zig / build.zig.zon
```

The library deliberately depends on `libsqlite3` via `linkSystemLibrary`
rather than re-using `libsmithers/src/persistence/sqlite.zig`. The
existing wrapper is tied to libsmithers' schema; this PoC mirrors the
same `extern fn` signatures in a focused `persistence.zig` so the FFI
surface is auditable in one file.

## Running the tests

### Tier 1 — fake server (no external deps)

```
zig build unit --summary all
```

~15 tests. They spawn an in-process `std.net.Server` on a throwaway
port and queue hand-crafted Electric responses, asserting protocol
correctness. All use `testing.allocator`; any leak fails the run.

### Tier 2 — real stack (gated)

```
cd /Users/williamcory/plue/poc/electric-go-consumer   # once it lands
docker compose up -d --build
export POC_ELECTRIC_STACK=1
export POC_ELECTRIC_SHAPE_HOST=127.0.0.1
export POC_ELECTRIC_SHAPE_PORT=3001
export POC_ELECTRIC_TOKEN=jjhub_deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
export POC_ELECTRIC_REPO_ID=1
export POC_ELECTRIC_BAD_REPO_ID=99999
zig build integration --summary all
```

When `POC_ELECTRIC_STACK` is unset the integration tests still compile
and run but degrade to `testing.expect(true)`, following the
"no t.Skip" convention from tickets 0094 / 0096.

## Known limits (v1)

- **HTTP only, no TLS.** plue's dev API is on port 4000 plaintext and
  the auth proxy sits on 3001 plaintext. Production deployment will
  put TLS in front; add `std.crypto.tls` once we know the deployment
  surface.
- **One shape per client.** Real libsmithers-core will multiplex many
  shapes; that's a scheduler concern, not protocol.
- **No retry/backoff.** The caller decides how to react to `IoError`,
  `Unauthorized`, `Forbidden`, etc. `pollOnce` is explicitly single-shot.
- **No streaming body.** We slurp the response into memory. Electric
  caps shape batches by server configuration; libsmithers-core may
  need streaming when shape fan-out is large.
- **Offset monotonicity only checked on `lsn_hi_lsn_lo` form.** Other
  formats (e.g. `-1`) are treated as non-regressing — intentional so
  the very-first request never trips the guard.

## Electric protocol quirks observed

- **Handle vs offset are orthogonal.** Handle identifies the
  server-side shape (a cache key); offset is the cursor. Both must
  be persisted together — losing either forces a full re-snapshot.
- **Control frames share the array with data messages.** `up-to-date`,
  `must-refetch`, and `snapshot-end` appear as list elements with a
  `headers.control` field instead of `headers.operation`. Parsers
  that only branch on `operation` miss them silently.
- **`electric-handle` arrives as an HTTP response header**, not in the
  JSON body. Missing the header on the first response is a hard fail.
- **`must-refetch` wipes everything.** Cursor, stored rows, the lot.
  The PoC clears the cursor but leaves row data to the caller since
  libsmithers' eventual schema is richer than our `poc_items`.
- **`connection: close` is the norm** for non-live requests. Electric
  streams via long-poll, not SSE in the shape API; the reverse-proxy
  FlushInterval of -1 in plue is there for a different endpoint.

## Authentication contract with plue

Plue's auth proxy (`plue/internal/electric/auth.go:44-136,250-282`)
enforces:

1. `Authorization: Bearer <jjhub_xxx|jjhub_oat_xxx>` — token hash
   lookup against `access_tokens` / `oauth2_access_tokens`.
2. `?where=` must contain `repository_id IN (...)` — no bare table
   subscriptions.
3. Every referenced `repository_id` must be readable by the token's
   owner (owner > org owner > team > collaborator > public).

The fake-server unit tests do not replicate the proxy's ACL logic;
they exercise the client. The Tier 2 tests exercise the proxy.

### Known gaps in plue's proxy (tracked as follow-up, not blockers for 0093)

- `repository_id IN (...)` match is case-sensitive; a client sending
  `REPOSITORY_ID IN (...)` bypasses the filter.
- An `OR` in the where clause lets non-matching predicates through.

Both are already noted in plue's backlog.
