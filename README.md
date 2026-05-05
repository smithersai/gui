# SmithersGUI

A native macOS SwiftUI application for managing smithers workflows, agent sessions, terminals, and tickets.

Requires **macOS 14 (Sonoma)** or later, **Apple Silicon (arm64)**.

> **Status: early / unstable.** SmithersGUI is in active development and is **not expected to be stable until ~mid-March 2027**. Expect crashes, broken flows, and breaking changes between releases. If you hit a bug, please send logs (see [Reporting bugs](#reporting-bugs) below).

## Download

[**Download SmithersGUI.dmg**](https://download.smithers.sh/SmithersGUI.dmg)
&nbsp; · &nbsp; [`.sha256`](https://download.smithers.sh/SmithersGUI.dmg.sha256)

> Releases are notarized through Apple's standard distribution flow. If macOS still blocks a local or development build, open **System Settings -> Privacy & Security**, scroll to the message about SmithersGUI being blocked, and click **Open Anyway**.

### Verify the binary

Verify the downloaded artifact against the published SHA-256 checksum:

```bash
# 1. download the artifacts
curl -LO https://download.smithers.sh/SmithersGUI.dmg
curl -LO https://download.smithers.sh/SmithersGUI.dmg.sha256

# 2. verify the checksum
shasum -a 256 -c SmithersGUI.dmg.sha256
```

## Reporting bugs

The app writes a structured JSON log to `~/Library/Logs/SmithersGUI/app.log`, and macOS drops native crash reports into `~/Library/Logs/DiagnosticReports/SmithersGUI-*.ips`. To send everything in one go, paste this into Terminal:

```bash
zip -j ~/Desktop/smithers-logs.zip \
  ~/Library/Logs/SmithersGUI/app.log \
  ~/Library/Logs/DiagnosticReports/SmithersGUI-*.ips 2>/dev/null
open -R ~/Desktop/smithers-logs.zip
```

That produces `~/Desktop/smithers-logs.zip` and reveals it in Finder. Attach the zip to your bug report along with:

- a short description of what you were doing
- the workspace folder you'd opened (path is fine — we don't need its contents)
- whether you were on the splash/welcome screen or inside a workspace when it broke

## Application data and settings

SmithersGUI keeps local app state in predictable macOS locations:

| Data | Location |
|---|---|
| App session database | `~/Library/Application Support/Smithers/app.sqlite` |
| App preferences | `defaults read com.smithers.SmithersGUI` |
| Shortcut settings file | `~/.config/smithers/settings.json` |
| App log | `~/Library/Logs/SmithersGUI/app.log` |
| Crash reports | `~/Library/Logs/DiagnosticReports/SmithersGUI-*.ips` |

Set `SMITHERS_APP_SUPPORT=/path/to/dir` before launching the app to move the app session database to another directory. Set `SMITHERS_SESSION_PERSISTENCE_DISABLE=1` to disable workspace/session persistence while testing.

### Default shell

Open **Settings -> Default shell** to choose the shell used for new terminal sessions. A custom path is used first when configured. The default "System default" path resolves in this order:

1. the login shell from the current user record
2. `SHELL` from the app environment
3. common macOS shells such as `/bin/zsh`, `/bin/bash`, and `/bin/sh`

The setting is stored in UserDefaults under `settings.defaultShellPath`.

## Dependencies

### Optional

The app degrades gracefully without these — specific features will be unavailable:

Install the common runtime extras with:

```bash
./scripts/install-optional-dependencies.sh
```

For build extras managed by Homebrew, run:

```bash
./scripts/install-optional-dependencies.sh --build-tools
```

| Dependency | What breaks without it | Install |
|---|---|---|
| **tmux** | Terminal multiplexing (split panes, named sessions) is disabled. Falls back to a single direct Ghostty shell per terminal surface. Searched at `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `/usr/bin/tmux`, and PATH. | `brew install tmux` |
| **git** | Session fork / timeline-replay fails. Error: `SessionForkError.gitUnavailable`. | `xcode-select --install` |
| **nvim** (Neovim) | "Open in Neovim" option for tickets is hidden. The built-in editor still works. Searched at `/opt/homebrew/bin/nvim`, `/usr/local/bin/nvim`, `/usr/bin/nvim`, and PATH. | `brew install neovim` |
| **Agent CLIs** (`claude`, `codex`, `gemini`, `kimi`, `amp`, `forge`) | Only agents whose CLI binary is found on PATH appear in the agent picker. Each requires its own API key (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`). | Install per agent's docs |

### Terminal surface (transitional, ticket 0123)

The terminal is being migrated from a macOS-only AppKit path to a
cross-platform SwiftUI surface fed by `libghostty`'s pipes backend via
`libsmithers-core`:

- `TerminalSurface.swift` — shared SwiftUI entry point used by both
  macOS and iOS. Bytes flow through `TerminalPTYTransport`.
- `TerminalView+macOS.swift` — macOS bridge that keeps the existing
  apprt-backed renderer.
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift` +
  `ios/Sources/SmithersiOS/Terminal/TerminalIOSCellView.swift` +
  `ios/Sources/SmithersiOS/Terminal/TerminalIOSGhostty.swift` — iOS
  Ghostty VT cell-grid renderer (SGR colors + cursor), backed by
  `ghostty-vt.xcframework`.
- iOS input behavior keeps both paths:
  on-screen `terminal.ios.input` / `terminal.ios.send` fallback for
  touch, plus hardware keyboard routing through
  `TerminalSurfaceModel.sendInput`.
- UITest placeholder mode is unchanged (`UITestSupport.isEnabled` still
  mounts `terminal.placeholder`).

Size overhead measurement (Release, `generic/platform=iOS`,
`CODE_SIGNING_ALLOWED=NO`, zipped `Payload/*.app` as `.ipa`):

- Before activation (placeholder path): `1,740,341` bytes
- After activation (Ghostty cell renderer): `2,915,886` bytes
- Delta: `+1,175,545` bytes (`+1.121 MB`) — within the `<= 2 MB` gate

For reference, the uncompressed `.app` bundle delta is `+3.469 MB`.

### Live-run DevTools reconnect + ghost budget

Live-run inspector tabs keep a per-run stream cursor (`afterSeq`) and
continue reconnecting from the last acknowledged sequence.

- Reconnect behavior:
  short blips (<2s) keep the current tree visible and avoid disruptive banners;
  longer interruptions show a stale-state banner ("stale since …") while
  preserving the last-known tree.
- Background tab behavior:
  run tabs keep their devtools/log subscriptions alive while backgrounded, so
  returning to a tab does not reset the stream cursor.
- Gap resync behavior:
  `GapResync` events force snapshot-first recovery (deltas are ignored until a
  follow-up snapshot arrives).
- Ghost retention:
  unmounted task nodes are retained in a ghost map so inspector selection/history
  stays resolvable.
- Memory envelope:
  `N × (active tree + buffered live events + ghost map)` for `N` concurrently
  open run tabs. Ghost retention is capped and oldest entries are evicted.
- Ghost cap:
  set `SMITHERS_DEVTOOLS_GHOST_CAP=<positive int>` to override the default cap
  (`256` ghost task entries per run store).

### Build-only

| Dependency | Version | Purpose |
|---|---|---|
| **macOS** | 14.0+ (Sonoma), Apple Silicon | Target platform — no Intel/Linux/Windows support |
| **Xcode** / Swift | 15+ / Swift 5.9+ | Compiler toolchain (`xcode-select --install` for CLI tools only is not enough — needs full Xcode for `xcodebuild`) |
| **Rust** | stable (1.80+) | Builds `libcodex_ffi.a` from `codex-ffi/` | Install via [rustup](https://rustup.rs) |
| **Zig** | **exactly 0.15.2** (pinned in `.zigversion`) | Build driver (`build.zig`) + required for rebuilding the Ghostty xcframework | Install via [zvm](https://github.com/tristanisham/zvm): `zvm install 0.15.2 && zvm use 0.15.2` |
| **xcodegen** | 2.43+ | Regenerates `SmithersGUI.xcodeproj` from `project.yml` | `brew install xcodegen` |
| **ViewInspector** (Swift package) | auto | Test-only dependency, fetched automatically | — |

> Zig has no official LTS release. We pin **0.15.2** (matching ghostty's `minimum_zig_version`) via `.zigversion`. `zvm` picks this up automatically when you `cd` into the repo. `build.zig` will hard-fail at compile time if the Zig version doesn't match.

## Building

### First-time setup

```bash
git clone --recursive https://github.com/smithersai/gui.git
cd gui
zvm use                 # picks up .zigversion (0.15.2)
zig build ghostty       # one-time, slow (~3-10 min). Builds GhosttyKit.xcframework.
zig build               # builds codex-ffi + SmithersGUI
```

If you already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

> **Why the separate ghostty step?** The Ghostty xcframework is a ~200 MB build artifact that isn't shipped in the ghostty submodule, so every fresh clone has to build it once. After that, it lives in `ghostty/macos/GhosttyKit.xcframework/` and day-to-day builds just reuse it. Rerun `zig build ghostty` only when you bump the ghostty submodule.

### Build commands

The project uses `build.zig` as a Makefile-style entrypoint. All common tasks go through `zig build <step>`:

| Command | What it does |
|---|---|
| `zig build` | Build everything needed to run the app (codex-ffi + `swift build`). Default step. |
| `zig build run` | Build then launch `.build/debug/SmithersGUI`. |
| `zig build codex-ffi` | Just the Rust FFI staticlib (`codex-ffi/target/release/libcodex_ffi.a`). |
| `zig build swift` | Just the Swift app via `swift build`. |
| `zig build xcode` | Build via `xcodebuild` (Debug). Pass `-Drelease=true` for Release. |
| `zig build xcodegen` | Regenerate `SmithersGUI.xcodeproj` from `project.yml`. Run this after editing `project.yml`. |
| `zig build test` | Run `cargo test` + `swift test`. |
| `zig build ghostty` | Rebuild `ghostty/macos/GhosttyKit.xcframework` from source. Slow; only needed if the vendored xcframework is missing or you want to update it. |
| `zig build clean` | `cargo clean` + `swift package clean`. |

Pass `-Drelease=true` to any build step for release-mode compilation.

### iOS Device Preview Backend

Physical iPhones cannot reach the Mac's `localhost:4000`. For preview
testing, build SmithersiOS with a reachable Smithers base URL baked into
`Info.plist`.

**Internet-reachable review with ngrok:**

```bash
# Terminal 1: keep this running
./ios/scripts/start-preview-tunnel.sh

# Terminal 2: build/install with the generated tunnel URL
source build/preview-tunnel/smithers-preview.env
DEVICE_ID=<device-identifier> INSTALL_ON_DEVICE=1 ./ios/scripts/build-for-device.sh
```

`start-preview-tunnel.sh` starts the local Smithers Docker stack if
`http://localhost:4000/api/health` is not already healthy, starts
`ngrok http 4000`, captures the HTTPS URL as `SMITHERS_PREVIEW_URL`, and
writes `SMITHERS_BASE_URL` exports to `build/preview-tunnel/smithers-preview.env`.

**Zero-egress LAN testing:**

```bash
./ios/scripts/build-for-device.sh
```

With no `SMITHERS_PREVIEW_URL` or `SMITHERS_BASE_URL`, the build script detects the
Mac's LAN IP with `ipconfig getifaddr en0`, bakes
`http://<LAN-IP>:4000` into `SmithersBaseURL`, and generates a temporary
Info.plist with a narrow ATS exception for that IP only. Override with
`SMITHERS_LAN_IP=...` or `SMITHERS_DEVICE_BASE_URL=...` when needed.

The OAuth2 redirect remains `smithers://oauth2/callback`; the app accepts
the `smithers` callback scheme and derives the backend base URL from the
baked `SMITHERS_BASE_URL` / `SMITHERS_PREVIEW_URL` value. No production Smithers
deploy is involved.

Validation sequence:

```bash
./ios/scripts/start-preview-tunnel.sh
source build/preview-tunnel/smithers-preview.env
DEVICE_ID=<device-identifier> INSTALL_ON_DEVICE=1 ./ios/scripts/build-for-device.sh
# Launch on device, tap Sign In, complete OAuth2, and return via smithers://.

LAN_URL="http://$(ipconfig getifaddr en0):4000"
curl -fsS "$LAN_URL/api/health"
```

### What actually gets built

- **`codex-ffi/`** — a standalone Rust crate in this repo that wraps `codex-core` via C ABI. Produces `libcodex_ffi.a` (~115 MB static archive) which Swift links against. Depends on codex crates via path into the `codex/` submodule.
- **`ghostty/macos/GhosttyKit.xcframework/`** — a prebuilt xcframework checked into the ghostty submodule. You normally don't need to rebuild this; `zig build ghostty` is only for toolchain updates.
- **SmithersGUI** — the Swift app itself, linking both of the above.

### Troubleshooting

- **`error: This project requires Zig 0.15.2. You have ...`** — run `zvm use` (reads `.zigversion`).
- **`ld: library 'codex_ffi' not found`** — you skipped the codex-ffi step. Run `zig build codex-ffi` (or just `zig build`).
- **`ld: library 'ghostty-fat' not found`** — the ghostty submodule wasn't initialized. Run `git submodule update --init --recursive`. If the `.xcframework` directory exists but is empty, you need to rebuild it with `zig build ghostty` (requires a working Zig toolchain with macOS SDK support).
- **Submodule clone fails or is empty** — make sure you cloned with `--recursive`, or run `git submodule update --init --recursive` after the fact.
