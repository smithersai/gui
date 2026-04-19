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

| Dependency | Purpose |
|---|---|
| **Swift 5.9+** / **Xcode 15+** | Compiler toolchain |
| **Rust toolchain** | Building `libcodex_ffi.a` from `codex/codex-rs` |
| **ViewInspector** (Swift package) | Test-only dependency, fetched automatically |
