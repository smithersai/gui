# SmithersGUI factory (`smithers.sh/smithersai/gui`)

Smithers 1.0 incremental CI and software factory for `smithersai/gui`.

- **Discovery:** `.smithers/WORKSPACE.ts`, the `PACKAGE.ts` files in
  `.smithers/`, `libsmithers/` and `Shared/`, and `.smithers/FACTORY.ts`.
  There is no `WORKSPACE.smithers`: smthrs 1.0.0-rc.18 discovers both names
  and refuses a workspace declared twice.
- **Cache:** results cache locally under `.smithers/cache` and sync through
  `https://build.smithers.sh` when `SMITHERS_CACHE_READ_TOKEN` and
  `SMITHERS_CACHE_WRITE_TOKEN` are set. Zig caches live under
  `.smithers/cache/tools/zig`; SwiftPM keeps `Shared/.build`.
- **Input closures:** each target hashes its own package's sources or a
  short file list, never the whole repository. A Swift edit reruns no Zig
  target, and a Zig edit never reruns the workflow helper tests.
- **Smithers 0.x workflows:** `.smithers/workflows/`, `agents.ts`, `tickets/`
  and `specs/` are the legacy workflow package that the GUI's own workflow
  views read. They are unchanged.

## Targets

| Label | Verb | Hosts | What it runs |
| --- | --- | --- | --- |
| `//libsmithers:build` | build | all | `zig build` into `libsmithers/zig-out` (static library, header, session helpers) |
| `//libsmithers:test` | test | all | `zig build test`: C ABI e2e, unit, daemon, devtools stream, core FFI and integration suites |
| `//libsmithers:test-build-script` | test | all | `zig test libsmithers/build.zig` (macOS SDK libsqlite3 slice selection) |
| `//libsmithers:fmt` | test | all | `zig fmt --check` on libsmithers sources |
| `//.smithers:hygiene` | test | all | Zig pin agreement, shell script syntax, factory JSON (`checks/repo-hygiene.mjs`) |
| `//.smithers:workflows-test` | test | all | `bun test` for the dependency-free workflow helpers (`parsing.ts`, `routing.ts`) |
| `//.smithers:factory-check` | build, lint | all | `factory.json` and `home.json` match `FACTORY.ts` and the discovered flows |
| `//.smithers:factory-write` | build, lint | all | regenerates `factory.json` and `home.json` with `--write` |
| `//Shared:test` | test (exclusive) | darwin | `swift test --package-path Shared` (about ten minutes cold) |

`//Shared:test` is exclusive: `smthrs ci //...` omits it unless
`--include-exclusive` is set, and Linux hosts never select it.

## Commands

Run from the repository root:

```sh
smthrs ci //...                                   # every default target, cached
smthrs test //Shared:test                         # Swift package tests (macOS)
smthrs affected ci //... --list                   # targets your edits select
smthrs explain //libsmithers:test                 # inputs and cache key
smthrs target //.smithers:factory-write --write   # after editing FACTORY.ts or flows
```

GitHub Actions runs `smthrs ci //...` in the `smthrs-ci` job of
`.github/workflows/ci.yml`; the macOS and iOS Xcode jobs are separate.

## Flows

| Flow | Purpose |
| --- | --- |
| `checks/review` | Review for C ABI ownership, SwiftUI platform guards, OAuth and Keychain safety, and build drift |
| `issue/repro` | Reproduce a defect at the lowest layer with a failing test or command |
| `issue/poc` | Implement a bounded fix with a regression and the affected targets green |
| `tickets/verify` | Check a `.smithers/tickets` ticket's criteria against code and tests |
| `pr-triage` | Assess a pull request from its diff and CI evidence without running its code |
