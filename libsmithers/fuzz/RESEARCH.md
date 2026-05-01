# Zig fuzz research for libsmithers

Date: 2026-04-21

## Installed version

`zig version` reports `0.15.2`, matching the repository pin.

## Local examples

Ghostty has fuzzing under `ghostty/test/fuzz-libghostty`, but it does not use
Zig's native `zig build --fuzz` runner. Its setup builds Zig static libraries
with `root_module.fuzz = true`, links them to `ghostty/pkg/afl++/afl.c`, and
runs AFL++ (`afl-fuzz`). This is useful as an example of deterministic harness
shape and fixed-size fuzz allocators, but it is not the framework requested for
libsmithers.

## Zig native fuzzing API in 0.14 and 0.15

Zig 0.14.0 release notes introduced an integrated alpha-quality fuzzer. The
documented pattern is a normal unit test that calls:

```zig
try std.testing.fuzz(context, testOne, .{});
```

and is run with:

```sh
zig build test --fuzz
```

The 0.14 notes say `--fuzz` rebuilds unit test binaries that contain fuzz tests
with `-ffuzz`, starts in-process fuzzing, and exposes a web UI.

Zig 0.15.1 release notes say the build web UI was generalized and that passing
`--fuzz` still exposes the fuzzer interface, mostly unchanged from 0.14.0. The
same notes say the fuzzer did not receive major development during the 0.15
cycle.

The installed Zig 0.15.2 standard library confirms the public API available in
this toolchain:

- `std.testing.FuzzInputOptions`
- `std.testing.fuzz(context, testOne, .{ .corpus = ... })`
- `zig build --fuzz`
- `zig test -ffuzz`

The prompt mentioned `std.testing.fuzzInput`, and one Zig compiler source file
in the installed tree references it, but `/Users/williamcory/.zvm/0.15.2/lib/std/testing.zig`
does not export `fuzzInput`. These harnesses therefore use `std.testing.fuzz`,
which is the API that exists in the pinned 0.15.2 standard library.

Sources checked:

- https://ziglang.org/download/0.14.0/release-notes.html#Fuzzer
- https://ziglang.org/download/0.15.1/release-notes.html#Fuzzer
- `/Users/williamcory/.zvm/0.15.2/lib/std/testing.zig`
- `/Users/williamcory/.zvm/0.15.2/lib/compiler/test_runner.zig`
- `/Users/williamcory/.zvm/0.15.2/lib/fuzzer.zig`

## Runtime and link requirements

Zig 0.15.2 ships its native fuzzer implementation as `lib/fuzzer.zig`. It is
compiled into fuzz-mode unit test binaries and communicates with the build
runner through shared memory-mapped files. No external Google libFuzzer library
is required at link time for these harnesses.

The relevant instrumentation path is Zig's built-in `-ffuzz` mode. The Zig
stdlib also exposes `sanitize_coverage_trace_pc_guard` for third-party fuzzers,
but the comments in `std.Build.Step.Compile` explicitly distinguish that path
from Zig's native fuzzer. The native fuzzer exports sanitizer-coverage hooks
such as `__sanitizer_cov_trace_cmp*`, `__sanitizer_cov_trace_switch`, and
`__sanitizer_cov_8bit_counters_init` from `lib/fuzzer.zig`.

Platform notes from the installed Zig source:

- `--fuzz` explicitly rejects Windows.
- `--fuzz` explicitly rejects 32-bit platforms.
- The 0.15.2 source does not explicitly reject 64-bit macOS, but this repository
  treats Linux Docker as the supported fuzz execution path so CI and macOS hosts
  get the same runtime and SQLite environment.

On macOS, `zig build` should still compile and run the corpus smoke tests. For
continuous fuzzing, use Docker unless you have already validated Zig 0.15.2
native fuzzing locally on your macOS setup.

## How to run

Local Linux:

```sh
cd libsmithers/fuzz
zig build test --fuzz
```

Individual targets:

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

macOS via Docker:

```sh
docker build -t libsmithers-fuzz libsmithers/fuzz
docker run --rm libsmithers-fuzz ./run.sh --short
```

Docker image requirements:

- Debian Linux base image
- Zig 0.15.2 Linux tarball for the build architecture
- SQLite development package for linking `libsmithers`
- `timeout` from GNU coreutils for bounded fuzz runs

The short run uses 30 seconds per target by default. The long run uses 10
minutes per target.
