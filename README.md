# SmithersGUI

A native macOS SwiftUI application for managing smithers workflows, agent sessions, terminals, and tickets.

Requires **macOS 14 (Sonoma)** or later, **Apple Silicon (arm64)**.

## Dependencies

### Required

These must be present at runtime or the app will not function:

| Dependency | How it's used | Install |
|---|---|---|
| **smithers** | Primary workflow engine — runs, approvals, cron, landings, tickets, scoring. The app shells out to `smithers` via PATH. | See smithers repo |
| **jjhub** | VCS operations — landings, issues, repository metadata. Shelled out via PATH. | See jjhub repo |
| **Codex FFI** (`libcodex_ffi.a`) | Rust FFI library powering agent execution. Vendored as a git submodule (`codex/`) and linked at compile time — no runtime install needed. | `git submodule update --init` then build with `codex/codex-rs` |
| **Ghostty** (`GhosttyKit.xcframework`) | Terminal emulator framework for all terminal surfaces. Vendored as a git submodule (`ghostty/`) and linked at compile time — no runtime install needed. | `git submodule update --init` then build the xcframework |
| **sqlite3** | Session persistence — chat history, terminal state, settings. Uses `/usr/bin/sqlite3` which ships with macOS. | Pre-installed on macOS |

### Optional

The app degrades gracefully without these — specific features will be unavailable:

| Dependency | What breaks without it | Install |
|---|---|---|
| **tmux** | Terminal multiplexing (split panes, named sessions) is disabled. Falls back to a single direct Ghostty shell per terminal surface. Searched at `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `/usr/bin/tmux`, and PATH. | `brew install tmux` |
| **git** | Session fork / timeline-replay fails. Error: `SessionForkError.gitUnavailable`. | `xcode-select --install` |
| **nvim** (Neovim) | "Open in Neovim" option for tickets is hidden. The built-in editor still works. Searched at `/opt/homebrew/bin/nvim`, `/usr/local/bin/nvim`, `/usr/bin/nvim`, and PATH. | `brew install neovim` |
| **Agent CLIs** (`claude`, `codex`, `gemini`, `kimi`, `amp`, `forge`) | Only agents whose CLI binary is found on PATH appear in the agent picker. Each requires its own API key (e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`). | Install per agent's docs |

### Build-only

| Dependency | Purpose |
|---|---|
| **Swift 5.9+** / **Xcode 15+** | Compiler toolchain |
| **Rust toolchain** | Building `libcodex_ffi.a` from `codex/codex-rs` |
| **ViewInspector** (Swift package) | Test-only dependency, fetched automatically |
