# SmithersGUI

A native macOS SwiftUI application for managing smithers workflows, agent sessions, terminals, and tickets.

Requires **macOS 14 (Sonoma)** or later, **Apple Silicon (arm64)**.

## Dependencies

### Optional

The app degrades gracefully without these — specific features will be unavailable:

| Dependency | What breaks without it | Install |
|---|---|---|
| **tmux** | Terminal multiplexing (split panes, named sessions) is disabled. Falls back to a single direct Ghostty shell per terminal surface. Searched at `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `/usr/bin/tmux`, and PATH. | `brew install tmux` |
| **git** | Session fork / timeline-replay fails. Error: `SessionForkError.gitUnavailable`. | `xcode-select --install` |
| **nvim** (Neovim) | "Open in Neovim" option for tickets is hidden. The built-in editor still works. Searched at `/opt/homebrew/bin/nvim`, `/usr/local/bin/nvim`, `/usr/bin/nvim`, and PATH. | `brew install neovim` |
| **Agent CLIs** (`claude`, `codex`, `gemini`, `kimi`, `amp`, `forge`) | Only agents whose CLI binary is found on PATH appear in the agent picker. Each requires its own API key (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`). | Install per agent's docs |

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
