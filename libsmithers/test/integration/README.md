# libsmithers Integration Suites

These suites exercise multi-function flows across the libsmithers core and C ABI.

- `app_lifecycle.zig`: app creation, workspace open/close, session creation, event draining, callback counts, and repeated embedded app lifetimes.
- `workspace.zig`: active workspace switching, two-workspace recents ordering, reopening an existing workspace, and close behavior.
- `palette.zig`: palette mode/query integration, JSON item shape, activation success, callback dispatch, and missing item errors.
- `client.zig`: golden `smithers_client_call` responses for common Smithers methods using deterministic mock JSON fixtures.
- `stream.zig`: client stream draining through `END`, free-after-end, and mid-stream `ERROR` lifecycle behavior.
- `persistence.zig`: SQLite session JSON save/load across reopen, 100-session byte-for-byte roundtrip, and two-thread save coverage.
- `action.zig`: core action callback trampoline coverage for every non-sentinel action tag and payload.
- `json_edges.zig`: Unicode, 1MB+ strings, empty arrays, nulls, and forward-compatible unknown fields through client and persistence paths.
- `error_paths.zig`: `out_err` failure/success behavior for client and persistence entry points plus owned error freeing.
- `memory_stress.zig`: 10k session/palette/text loop using the test allocator to catch non-steady memory behavior.
