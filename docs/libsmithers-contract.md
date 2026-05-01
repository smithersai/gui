# libsmithers integration contract

**Header:** [`libsmithers/include/smithers.h`](../libsmithers/include/smithers.h)

## Status

`libsmithers` now exposes only the modern runtime ABI:

- `smithers_core_*` for authenticated engine sessions, shape subscriptions,
  cache reads, writes, and PTY attachments.
- `smithers_obs_*` for process-wide observability events and metrics.
- Shared `smithers_string_s`, `smithers_error_s`, and `smithers_bytes_s` free
  helpers.

The legacy app/session/client/palette/persistence ABI has been removed. New
callers must not add `smithers_app_*`, `smithers_session_*`,
`smithers_client_*`, `smithers_palette_*`, `smithers_persistence_*`, or generic
JSON method-dispatch exports back to the public header.

## Runtime Contract

1. The header in `libsmithers/include/smithers.h` is the source of truth.
2. Opaque handles cross the ABI only as the modern runtime handles:
   `smithers_core_t`, `smithers_core_session_t`, subscription ids, write future
   ids, and PTY handles.
3. Authentication is host-provided through `smithers_credentials_fn`; the core
   does not read GUI tokens from disk.
4. Shape data is read through `smithers_core_cache_query`; mutations go through
   `smithers_core_write` and are confirmed by runtime events/cache echo.
5. Returned strings, errors, and byte buffers are owned by libsmithers until the
   matching free function is called exactly once.

## Local GUI Helpers

Local-only conveniences such as workflow source editing, slash parsing, command
palette state, recent workspaces, terminal tmux helpers, devtools transforms, and
workflow frontend discovery are Swift-side helpers or direct CLI calls. They are
not part of the libsmithers C ABI.

## Verification

Expected checks for ABI changes:

```sh
cd libsmithers && zig build test
cd .. && swift build
```

Also search the public bridge for removed symbols:

```sh
rg "smithers_(app_|session_|client_|palette_|persistence_|slashcmd_|cwd_)|smithers_app_t|smithers_client_t" \
  libsmithers/include/smithers.h macos/Sources/Smithers
```
