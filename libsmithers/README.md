# libsmithers

`libsmithers` is the Zig runtime core for SmithersGUI. Its public C ABI is the
modern `smithers_core_*` connection runtime plus the process-wide
`smithers_obs_*` observability API declared in `include/smithers.h`.

The old app/session/client/palette/persistence ABI has been removed. Local app
helpers that used to route through `smithers_client_call` now live in Swift or
use the `smithers` / `jjhub` CLIs directly; signed-in runtime behavior uses
`smithers_core_*`.

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

- `src/core/` owns engine sessions, Electric shape subscriptions, cache queries,
  writes, and PTY attachments exposed as `smithers_core_*`.
- `src/obs.zig` and `src/obs_ffi.zig` expose process-wide observability events
  and metrics as `smithers_obs_*`.
- `src/ffi.zig`, `src/ffi_exports.zig`, and `src/apprt/structs.zig` provide the
  shared string/error/bytes allocation helpers used by the ABI.
- `../zmux/` owns the standalone tmux-style PTY session daemon used by local
  terminal paths. `libsmithers` still installs compatibility helper names for
  the app bundle, but those binaries compile from the zmux package.

## Testing

`zig build test` runs the modern core, cache, transport, FFI smoke, and session
daemon coverage. Compatibility tests for the deleted legacy ABI are intentionally
not part of the test step.
