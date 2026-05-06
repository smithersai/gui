# Reference App Feature Parity

Last updated: 2026-05-01

Reference clones used for this pass:

- `TGlide/thom-chat` cloned at `/tmp/smithers-refs/thom-chat`
- `pingdotgg/t3code` cloned at `/tmp/smithers-refs/t3code`

## Reference Capabilities

### thom.chat / T3 Chat-style UX

Source: <https://github.com/TGlide/thom-chat>

Relevant capabilities:

- Multi-model chat through OpenRouter
- Server-side streaming that survives reloads
- Chat branching and message regeneration
- Full-text chat history search
- Privacy mode for screen sharing
- File uploads with image support
- Web search integration
- Markdown rendering with syntax highlighting
- Public conversation sharing
- Rules, shortcuts, and prompt enhancement

### T3 Code-style Agent App

Source: <https://github.com/pingdotgg/t3code>

Relevant capabilities:

- Desktop app for coding agents with Codex, Claude, and OpenCode provider slots
- Runtime mode switch: full access vs supervised
- Provider availability and model selection surfaced in the UI
- WebSocket transport with typed request/response and validated push events
- Terminal/event streaming with reconnect-oriented client state
- Git branch/worktree context and PR-oriented actions
- Deterministic worker drains and transport tests around provider events

## Tabmonsters Parity Snapshot

| Area | Tabmonsters state | Parity status | Next action |
| --- | --- | --- | --- |
| Live workflow/run inspection | Native run inspector, task tree, logs, outputs, approvals | Strong | Keep hardening reconnect and snapshot coverage |
| Agent/provider availability | `AgentsView` lists detected CLIs, auth/API-key hints | Partial | Add provider/model selection per chat/run creation |
| Transcript rendering | Role-aware blocks, noise filtering, copy transcript, and language-labeled fenced code panels | Partial | Add inline markdown and full syntax highlighting parity |
| Privacy/screen-share mode | Added this pass for Logs transcript render and copy | Implemented | Consider persisting preference across app launches |
| Chat branching/regeneration | Run-level fork/replay exists, message-level branching not surfaced | Partial | Design transcript-level branch/fork affordance |
| Full-text chat search | Current Logs transcript can be searched by role/content with copied transcript respecting the filter | Partial | Add searchable transcript index across saved runs/nodes |
| File/image attachments | Some chat surfaces have attachment affordances/stubs | Partial | Route attachments into Smithers/JJHub workflows |
| Web search | Browser/workflow surfaces exist, prompt-level web search not exposed | Partial | Add explicit tool toggle/status in chat composer |
| Public sharing | No public transcript sharing flow identified | Missing | Decide if share links are product-appropriate |
| Runtime modes | Smithers approvals exist, but no T3 Code-style mode switch | Partial | Add full/supervised mode control when launching agents |
| Transport robustness | DevTools stream gap/reconnect handling exists, and active streams now cancel when the store is released | Strong | Continue schema-boundary decode tests |

## Completed In This Pass

- Added `ChatPrivacyRedactor` for role-specific privacy placeholders.
- Added `privacyMode` to `LogsTabModel`.
- Added a Logs toolbar Privacy toggle.
- Routed privacy mode through `ChatBlockRenderer` and transcript copy.
- Added current-run transcript search in Logs with role/content matching and filtered copy output.
- Added fenced-code parsing and language-labeled code panels inside transcript blocks.
- Hardened reconnect tests so a missing expected stream call fails cleanly instead of crashing on an unchecked array index.
- Hardened `DevToolsStore` stream lifecycle so an active stream no longer retains the store after the view/model drops it.
- Added deterministic cleanup to store stream tests that connect to mock providers.
- Moved session persistence debounce off a sleeping Swift task to avoid cancellation surfacing as an XCTest failure.
- Made real-PTY E2E tests skip when the host daemon reports `OpenPtyFailed`, while keeping non-PTY persistence/model coverage active.
- Removed GCD scheduling flakiness from the steady scrubber debounce test.
- Fixed root SwiftPM test compilation by excluding the standalone `AgentApp` package from the main target.
- Added tests for redacted rendering and redacted copy output.
- Added tests for transcript search and search-filtered transcript copy.
- Added tests for fenced-code transcript rendering.
- Added a lifecycle regression test proving `DevToolsStore` deallocation terminates an active stream.

Verification:

- `swift test --jobs 1 --filter LogsTabTests`
- `swift test --jobs 1 --filter ChatBlockRendererTests`
- `swift test --jobs 1 --filter DevToolsCLITransportReconnectTests`
- `swift test --jobs 1 --filter LiveRunDevToolsStoreTests`
- `swift test --jobs 1 --filter StoreScrubTests`
- `swift test --jobs 1 --filter ScrubberDebounceTests`
- `swift test --jobs 1 --filter NativeTerminalRestoreTests`
- `swift test --jobs 1 --filter SessionPersistenceE2ETests`
- `swift test --jobs 1 --filter SessionStore`
- `swift test --jobs 1 --filter Workspaces`

Known verification caveat:

- `swift test --jobs 1` still exits with signal 13 in aggregate runs even after the concrete `ScrubberDebounceTests`, native PTY, and session persistence failures were fixed or environment-skipped. The latest observed aggregate interruption occurred around `StoreScrubTests` / `SurfaceNotificationStoreCoverageTests` with no failing XCTest assertion in the log; the focused suites above pass.
