# libsmithers Zig fuzzing

This package contains native Zig fuzz tests for libsmithers. It is pinned to
Zig 0.15.2 and uses `std.testing.fuzz`.

## Targets

- `slash`: `smithers_slashcmd_parse`
- `cwd`: `smithers_cwd_resolve` plus the internal resolver for embedded NULs
- `client`: `smithers_client_call`
- `persistence`: `smithers_persistence_save_sessions`
- `action`: action tag and C payload conversion
- `palette`: command palette queries
- `models`: Smithers model JSON round trips
- `event`: event stream JSON array serialization

## Smoke tests

From `libsmithers/fuzz`:

```sh
zig build
```

This compiles every target and runs the checked-in seed corpus once. It does not
start continuous fuzzing unless `--fuzz` is passed to the build runner.

## Native fuzzing on Linux

Run all targets:

```sh
zig build test --fuzz
```

Run one target:

```sh
zig build run-slash --fuzz
zig build run-cwd --fuzz
zig build run-client --fuzz
zig build run-persistence --fuzz
zig build run-action --fuzz
zig build run-palette --fuzz
zig build run-models --fuzz
zig build run-event --fuzz
```

Zig's fuzzer keeps running until interrupted. The build runner prints a local
web UI URL with coverage information.

## Docker on macOS

The supported macOS path is Docker:

```sh
cd libsmithers/fuzz
./run.sh --short
```

Or explicitly:

```sh
docker build -t libsmithers-fuzz libsmithers/fuzz
docker run --rm libsmithers-fuzz ./run.sh --short
```

The Dockerfile is written for that exact build context. Since Docker cannot copy
files outside `libsmithers/fuzz` when that context is used, it clones
`smithersai/gui` inside the image and overlays the local fuzz directory from the
build context.

`--short` runs each target for 30 seconds. `--long` runs each target for 10
minutes.

## Crash output

If `run.sh` sees a non-timeout failure, it writes:

```text
crashes/<target>/<timestamp>/report.md
crashes/<target>/<timestamp>/input.bin
crashes/<target>/<timestamp>/fuzz.log
```

`input.bin` is the newest native Zig fuzzer corpus file the script can identify
from `.zig-cache`. If no current input is available, the report says so.

## Reducing crashes

1. Put the crashing bytes in the target corpus directory, for example
   `corpus/slash/crash.bin`.
2. Add an `@embedFile("../corpus/slash/crash.bin")` entry to that target's
   corpus list.
3. Run `zig build run-slash` to replay without continuous fuzzing.
4. Delete chunks from the corpus file and rerun until the smallest crashing
   input remains.

Do not fix libsmithers source from this package. Record confirmed source bugs as
`CRASH_<slug>.md` under `libsmithers/fuzz`.
