# SmithersGUI

A native macOS SwiftUI application for managing smithers workflows, agent sessions, terminals, and tickets.

Requires **macOS 14 (Sonoma)** or later, **Apple Silicon (arm64)**.

> **Status: early / unstable.** SmithersGUI is in active development and is **not expected to be stable until ~mid-March 2027**. Expect crashes, broken flows, and breaking changes between releases. If you hit a bug, please send logs (see [Reporting bugs](#reporting-bugs) below).

## Download

[**Download SmithersGUI.dmg**](https://download.smithers.sh/SmithersGUI.dmg)
&nbsp; · &nbsp; [`.sha256`](https://download.smithers.sh/SmithersGUI.dmg.sha256)
&nbsp; · &nbsp; [`.sig`](https://download.smithers.sh/SmithersGUI.dmg.sig)

> **Unsigned by Apple.** On first launch macOS will refuse to open it ("can't be opened because Apple cannot check it for malicious software"). To allow it: open **System Settings → Privacy & Security**, scroll to the message about SmithersGUI being blocked, and click **Open Anyway** (you'll be prompted for your password). macOS will remember this for future launches. Verifying the eth signature below is the way to confirm the binary is the one we built.

### Verify the binary

Releases are signed with a secp256k1 key (an Ethereum wallet) so you can prove the DMG you downloaded is the same bits we built — no Apple Developer ID required.

**Signer address:** `0xA1aaEC6B60547BE8677247f9Eb2d9fCc975496fb`

The signature is over the SHA-256 of the DMG. Verify with [foundry's `cast`](https://book.getfoundry.sh/getting-started/installation):

```bash
# 1. download the artifacts
curl -LO https://download.smithers.sh/SmithersGUI.dmg
curl -LO https://download.smithers.sh/SmithersGUI.dmg.sig

# 2. hash the DMG and verify the signature recovers the signer address
HASH=0x$(shasum -a 256 SmithersGUI.dmg | awk '{print $1}')
SIG=$(cat SmithersGUI.dmg.sig)
cast wallet verify --address 0xA1aaEC6B60547BE8677247f9Eb2d9fCc975496fb "$HASH" "$SIG"
# → prints "Validation succeeded." on a good signature
```

If `cast wallet verify` succeeds, the DMG matches what was signed by the holder of the private key (stored in the maintainer's macOS Keychain — see `scripts/init-signing-key.ts` and `scripts/sign-dmg.ts`).

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

## Dependencies

### Optional

The app degrades gracefully without these — specific features will be unavailable:

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

- `TerminalSurface.swift` — shared SwiftUI entry point. Compiles on
  macOS + iOS. Driven by byte streams from a `TerminalPTYTransport`.
- `TerminalView+macOS.swift` — macOS bridge that delegates to the
  existing apprt-backed `TerminalSurfaceRepresentable` (in
  `TerminalView.swift`, now guarded `#if os(macOS)`).
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift` — iOS
  UITextView renderer over the shared model. libghostty VT-level
  rendering (via `ghostty-vt.xcframework` from the 0092 PoC) replaces
  this body in a follow-up.

Compatibility note: `RuntimePTYTransport` is wired through 0120's
`SmithersRuntime` wrapper but the 0120 runtime still ships a fake
transport with no real byte stream. macOS therefore continues to use
the legacy `smithers-session-daemon` path inside
`TerminalSurfaceRepresentable` during migration. Once the 0094
WebSocket PTY lands and 0120's transport graduates, flip shared
callers off `TerminalView` (macOS-only) onto `TerminalSurface` and
delete the daemon fallback.

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

### What actually gets built

- **`codex-ffi/`** — a standalone Rust crate in this repo that wraps `codex-core` via C ABI. Produces `libcodex_ffi.a` (~115 MB static archive) which Swift links against. Depends on codex crates via path into the `codex/` submodule.
- **`ghostty/macos/GhosttyKit.xcframework/`** — a prebuilt xcframework checked into the ghostty submodule. You normally don't need to rebuild this; `zig build ghostty` is only for toolchain updates.
- **SmithersGUI** — the Swift app itself, linking both of the above.

### Troubleshooting

- **`error: This project requires Zig 0.15.2. You have ...`** — run `zvm use` (reads `.zigversion`).
- **`ld: library 'codex_ffi' not found`** — you skipped the codex-ffi step. Run `zig build codex-ffi` (or just `zig build`).
- **`ld: library 'ghostty-fat' not found`** — the ghostty submodule wasn't initialized. Run `git submodule update --init --recursive`. If the `.xcframework` directory exists but is empty, you need to rebuild it with `zig build ghostty` (requires a working Zig toolchain with macOS SDK support).
- **Submodule clone fails or is empty** — make sure you cloned with `--recursive`, or run `git submodule update --init --recursive` after the fact.
