# smithers-cli

Standalone Zig command-line frontend for `libsmithers`. The CLI does not talk
to the Smithers daemon or JJHub directly; every command goes through the
`smithers.h` ABI.

## Build

Build `libsmithers.a` first, then build the CLI:

```sh
cd /Users/williamcory/gui/libsmithers
zig build

cd /Users/williamcory/gui/libsmithers/cli
zig build
zig build test
```

The binary is installed at:

```sh
/Users/williamcory/gui/libsmithers/cli/zig-out/bin/smithers-cli
```

## Global Flags

```sh
smithers-cli --help
smithers-cli --version
smithers-cli --json info
smithers-cli --verbose event drain
```

Errors are written to stderr as `error: <msg>`. With `--json`, a structured
error object is also written to stderr.

## Commands

```sh
smithers-cli info
```

Calls `smithers_info()` and prints version, commit, and platform.

```sh
smithers-cli cwd resolve
smithers-cli cwd resolve ~/work/project
```

Calls `smithers_cwd_resolve()` and prints the resolved path.

```sh
smithers-cli workspace list
smithers-cli workspace open /path/to/workspace
```

Calls `smithers_app_recent_workspaces_json()` or
`smithers_app_open_workspace()`.

```sh
smithers-cli slash parse "/build foo"
```

Calls `smithers_slashcmd_parse()` and prints the parsed JSON.

```sh
smithers-cli palette query terminal --mode commands
smithers-cli palette query run --mode all
```

Creates a palette, configures mode/query, calls
`smithers_palette_items_json()`, and prints the JSON items.

```sh
smithers-cli session new --kind chat --workspace /path/to/repo --target run-1
smithers-cli session title transient:<SESSION_ID_FROM_SESSION_NEW>
```

Creates a transient session with `smithers_session_new()` and prints metadata.
`session title` decodes the transient ID emitted by `session new`, reconstructs
the session in the current process, and calls `smithers_session_title()`.

```sh
smithers-cli client call listRuns --args '{"mockResult":[{"runId":"run-1"}]}'
smithers-cli client stream streamChat --args '{"events":[{"token":"a"},{"token":"b"}]}'
```

Calls `smithers_client_call()` or `smithers_client_stream()`. Streaming events
are emitted as NDJSON, one event payload per line.

```sh
smithers-cli persistence load --db /tmp/sessions.sqlite --workspace /path/to/repo
printf '[{"id":"s1","kind":"chat"}]' | \
  smithers-cli persistence save --db /tmp/sessions.sqlite --workspace /path/to/repo --input -
```

Opens persistence through `smithers_persistence_open()` and calls the JSON
load/save ABI.

```sh
smithers-cli event drain
smithers-cli --json event drain
```

Internal development command. It constructs an app with default no-op
callbacks, ticks once, and prints any drain output available through the current
ABI.
