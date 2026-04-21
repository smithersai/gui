# libsmithers

`libsmithers` is the Zig core for SmithersGUI. It owns runtime-agnostic business
logic and exposes the narrow C ABI declared in `include/smithers.h`.

## Build

Requires Zig 0.15.2.

```sh
cd libsmithers
zig build
zig build test
```

The default build produces `zig-out/lib/libsmithers.a` and installs
`smithers.h` into `zig-out/include/`.

## Architecture

- `src/apprt/embedded.zig` contains every exported `smithers_*` C ABI function.
- `src/apprt/action.zig` and `src/apprt/structs.zig` mirror the public ABI
  structs, enums, opaque-handle conventions, and tagged-union action pattern.
- `src/App.zig` owns workspaces, recents, sessions, runtime callbacks, and
  state-change notifications.
- `src/session/` provides long-lived session handles and JSON event streams.
- `src/client/` exposes the SmithersClient surface through `smithers_client_call`
  and `smithers_client_stream`; tests use JSON mock fixtures.
- `src/models/` keeps Smithers and app models as JSON-only contracts.
- `src/commands/` ports slash command parsing and command palette scoring.
- `src/workspace/` ports CWD resolution and launch workspace parsing.
- `src/persistence/` stores session JSON in SQLite.

## Testing

`test/e2e.zig` covers every public ABI function in `smithers.h`, model JSON
round trips, SQLite persistence, slash and palette golden cases, CWD edge cases,
client call/stream fixtures, and action tag conversion.
