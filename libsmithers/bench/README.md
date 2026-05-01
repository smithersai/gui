# libsmithers Benchmarks

Standalone zbench suite for libsmithers hot paths. The executable links
`../zig-out/lib/libsmithers.a` and uses Zig 0.15.2.

## Setup

```sh
cd /Users/williamcory/gui/libsmithers
zig build

cd /Users/williamcory/gui/libsmithers/bench
zig build
./zig-out/bin/smithers-bench
./zig-out/bin/smithers-bench --group palette
```

`build.zig.zon` pins zbench `v0.11.2`, the latest tag I found that builds with
Zig 0.15.2. zbench `v0.13.0` declares a Zig 0.16 development minimum. No
vendored fallback is used.

## Groups

- `cwd`: `smithers_cwd_resolve` on null/default, `/`, existing absolute cwd,
  and invalid fallback inputs.
- `slash`: `smithers_slashcmd_parse` for `/foo`, `/foo arg1 arg2`,
  `/foo --flag=value`, and malformed non-slash text.
- `palette`: query plus JSON scoring for 10, 1k, and 100k synthetic workspace
  candidates. The public palette ABI has no safe bulk-load hook for large
  backing stores, so this mirrors the current libsmithers scorer/serializer.
- `client`: `smithers_client_call` local `echo` calls, avoiding network and CLI
  fallback.
- `stream`: `smithers_event_stream_next` drain loops over fixture streams of
  10, 1k, and 10k events.
- `persistence`: SQLite save+load round trips for 1, 10, 100, and 1000
  sessions.
- `json`: model JSON parse/stringify round trips for RunSummary, Workflow,
  ChatBlock, Ticket, and SearchResult payloads.
- `action`: current action conversion path, `cvalAlloc`, for every variant and
  back into a Zig union.
- `lifecycle`: app_new + one workspace + one chat session + free, cold and
  warm.

Each measured function creates a fresh arena allocator. zbench allocation
tracking only sees allocations through that allocator; libsmithers C ABI return
values use `std.heap.c_allocator`, are freed, and are not visible in the
allocation columns.

Rows with standard deviation greater than 20% of the mean are flagged as noisy.
Palette rows over 10 ms are flagged as cliffs.

## Host Baseline

Host: Apple M3 Max, arm64, macOS 26.2, Zig 0.15.2.

Full committed output is in `baseline.txt`. Representative run:

```text
palette.query_json_100k             16     15336580       124256            3         1045     6520358.52 items/s  cliff >10ms
persistence.roundtrip_1000          32      6139325       171257            0            0      162884.36 sessions/s  -
stream.drain_10k                     3     62447833       194578            0            0      160133.66 events/s  -
```

Notable findings from this baseline:

- `smithers_cwd_resolve` is not sub-microsecond on this host; the current
  implementation does cwd/env/path directory work and lands around 14-27 us.
- Palette query over 100k candidates is a real cliff at roughly 15 ms.
- C ABI allocation columns are zero because those allocations happen inside
  libsmithers' C allocator; JSON/action synthetic/internal paths show tracked
  arena allocations.
