# Platform And Navigation Review

Review scope: `PLATFORM_AND_NAVIGATION` feature group, focused on `ContentView.swift`, `SidebarView.swift`, `SessionStore.swift`, `SessionPersistenceStore.swift`, `CWDResolver.swift`, `SmithersClient.swift`, `AgentService.swift`, `TerminalView.swift`, module maps/headers, and the related test files.

## Findings

### High: Ghostty runtime clipboard callbacks cast userdata to the wrong type

`TerminalView.swift:173` stores `GhosttyApp` in `runtime.userdata`, and `TerminalView.swift:175` correctly casts that pointer back to `GhosttyApp` in `wakeup_cb`. The clipboard callbacks use the same runtime userdata but cast it to `TerminalSurfaceView` at `TerminalView.swift:183` and `TerminalView.swift:189`.

That is type confusion across unmanaged pointers. Any Ghostty clipboard read/confirm path can crash or corrupt memory when the callback tries to use a `GhosttyApp` instance as a `TerminalSurfaceView`. The existing `TerminalViewTests` mostly document expected C integration behavior and do not exercise these callbacks.

Recommendation: either make the runtime-level callbacks route through `GhosttyApp` to the active surface, or store a stable callback coordinator object in runtime userdata. Add a test that invokes the Swift callback closures with a controlled unmanaged object so the expected cast is enforced.

### High: Terminal tabs are created but their ids are not passed into `TerminalView`

`SidebarView.swift:259` creates a terminal tab id through `SessionStore.addTerminalTab()`, and `SessionStore.swift:204` stores the tab. `ContentView.swift:55` handles `.terminal(let id)`, but the destination creates `TerminalView()` and only applies `.id(id)` at `ContentView.swift:57`. `TerminalView.swift:1036` has a `sessionId` parameter, and `TerminalSurfaceRepresentable` only uses `TerminalSurfaceRegistry` when that value is non-nil at `TerminalView.swift:1003`.

The result is that sidebar terminal tab identity and Ghostty surface identity are separate. SwiftUI may recreate the destination for a different tab id, but the terminal view is not registered under that tab id, so the registry path is bypassed for normal navigation. This weakens `PLATFORM_GHOSTTY_TERMINAL_EMBED` and the new terminal tab behavior.

Recommendation: pass the route id into `TerminalView(sessionId: id)`. For command terminals, decide whether `.terminalCommand` should also carry a stable id so command-backed terminal state survives navigation consistently.

### High: SessionStore resolves a working directory but does not give it to AgentService

`SessionStore.swift:66` resolves `workingDirectory`, but `newSession()` constructs `AgentService` without a `workingDir:` argument at `SessionStore.swift:99`, and persisted sessions are also restored without one at `SessionStore.swift:399`. `AgentService.swift:224` does resolve and store its own working directory, but only from the value it is given.

This means `PLATFORM_CWD_AUTO_DETECTION_WITH_HOME_FALLBACK` is not consistently connected to the Codex bridge execution path. The UI/session layer may resolve a project cwd, while the agent falls back to its own default.

Recommendation: store the resolved cwd on `SessionStore` and pass it into every `AgentService` created by the store, including restored sessions. Add a regression test using a real temporary directory and assert `SessionStore(workingDirectory: temp).activeAgent?.workingDirectory == temp`.

### Medium: CWD tests and AgentService behavior disagree on explicit nonexistent paths

`CWDResolver.swift:21` now falls back to home when a candidate path does not exist or is not a directory. That behavior is defensible for auto-detection, but `AgentServiceTests/testWorkingDirectory` still expects an explicit nonexistent path like `/tmp/myproject` to remain unchanged.

Verification found this test currently fails:

```text
AgentServiceTests.testWorkingDirectory
XCTAssertEqual failed: "/Users/williamcory" is not equal to "/tmp/myproject"
```

Some `CWDResolverAdditionalTests` also use nonexistent paths such as `/Users/test/project` and `/valid/path`, so the suite is not cleanly documenting whether explicit paths should be validated or preserved.

Recommendation: split the policy into explicit and auto-detected cwd cases. Either preserve explicit paths and only home-fallback detected `/`, missing, or non-directory values, or update the tests and user-visible behavior to state that all nonexistent explicit paths are rejected.

### Medium: Default session title does not match the feature name

`SessionStore.defaultChatTitle` is `"Claude Code"` at `SessionStore.swift:17`, and `newSession()` uses that value at `SessionStore.swift:107`. The feature list calls out `PLATFORM_SESSION_DEFAULT_TITLE_NEW_CHAT`, and the tests assert the constant instead of the product requirement, so this mismatch is not caught.

Recommendation: confirm the intended product copy. If the feature requirement is literal, change the constant to `"New Chat"` and add a test that asserts the required string directly. If `"Claude Code"` is intentional, rename the feature/test descriptions so they match the implementation.

### Medium: Persisted session timestamps can become stale after messages

`SessionStore.swift:443` updates the in-memory session preview and timestamp when messages change, then persists session metadata and messages. `SessionStore.swift:570` calls `createSession`, and `SessionPersistenceStore.swift:142` uses `INSERT OR IGNORE`, so existing session rows do not get their `updated_at` refreshed. Message triggers at `SessionPersistenceStore.swift:340` update message metadata and counts, but not the parent session timestamp.

This affects `PLATFORM_SESSION_RELATIVE_TIMESTAMPS`, `PLATFORM_SESSION_GROUPING_BY_DATE`, and `PLATFORM_SESSION_INSERT_AT_TOP` after restart. A session can appear current in memory while later reloading from SQLite with its original timestamp.

Recommendation: add an explicit session upsert/update when persisting message changes, or add message insert/update triggers that refresh `sessions.updated_at`. Add tests that create two sessions, append a later message to the older one, reload from persistence, and assert ordering/grouping.

### Medium: SQLite persistence is synchronous on the MainActor and can deadlock on large output

`SessionStore` is `@MainActor` at `SessionStore.swift:15`, and message updates call persistence from the main actor at `SessionStore.swift:443`. `SessionPersistenceStore.runSQLite` starts `/usr/bin/sqlite3` at `SessionPersistenceStore.swift:400`, then waits synchronously at `SessionPersistenceStore.swift:415` before reading stdout and stderr at `SessionPersistenceStore.swift:417`.

This can freeze the UI during streaming persistence. It can also deadlock if sqlite output or diagnostics fill a pipe before the process exits.

Recommendation: move persistence behind a dedicated actor or queue, or switch to a native SQLite binding. If the process wrapper remains, read stdout/stderr concurrently before `waitUntilExit()`.

### Medium: Codex cancellation cannot interrupt bridge creation

`AgentService.sendMessage` creates the Codex bridge in a detached task at `AgentService.swift:317`, but `CodexBridge` initialization calls into `codex_create_with_options` before any handle is activated. `AgentService.cancel()` at `AgentService.swift:366` can cancel the task and cancel an active bridge, but it has no handle while creation is blocked.

If FFI bridge creation hangs or is slow, `PLATFORM_CODEX_CANCEL` will not take effect until after creation returns. The code does discard a bridge if activation fails after cancellation, but that still leaves the blocking create call uninterruptible.

Recommendation: add a timeout or cancellation-aware create API at the FFI boundary. At minimum, add a test double for lifecycle creation that blocks until cancelled so the behavior is explicitly documented.

### Low: The selected default route is hidden inside a collapsed sidebar section

`ContentView.swift:13` defaults to `.dashboard`. The Smithers section is collapsed by default at `SidebarView.swift:99` and in the initializer defaults at `SidebarView.swift:112`. The dashboard row is inside that collapsed section at `SidebarView.swift:176`.

The app opens with Dashboard selected, but the selected row is not visible in the sidebar. That is a navigation polish issue for `PLATFORM_SIDEBAR_NAVIGATION` and `PLATFORM_DESTINATION_ROUTING`.

Recommendation: expand the section containing the active destination by default, or auto-expand a section whenever its selected child is active.

### Low: Connection flags mix CLI availability and server health

`SmithersClient.checkConnection()` sets `cliAvailable` from `smithers --version` at `SmithersClient.swift:3348`. If no server URL is configured, `isConnected` mirrors CLI availability at `SmithersClient.swift:3357`. If a server URL is configured, `isConnected` becomes HTTP health only at `SmithersClient.swift:3376`.

That makes `PLATFORM_SMITHERS_CLI_AVAILABLE_FLAG`, `PLATFORM_SMITHERS_IS_CONNECTED_FLAG`, and `PLATFORM_SMITHERS_SERVER_URL_OPTIONAL` ambiguous. The CLI can be available while `isConnected` is false because a configured server is down.

Recommendation: expose separate concepts such as `cliAvailable`, `serverReachable`, and `transportUsable`, or document that `isConnected` means the selected transport is connected.

## Coverage Review

The codebase has meaningful coverage for many navigation and session features, especially enum identity, sidebar rows, session CRUD, JSONL line buffering, and CLI command construction. The risk is that a significant part of the suite is source-inspection or documentation-style testing rather than behavior testing.

Specific gaps:

- `ContentViewTests.swift:77`, `ContentViewTests.swift:99`, `ContentViewTests.swift:463`, and `ContentViewTests.swift:487` contain empty or stale `BUG` tests. For example, keyboard shortcuts now exist in `ContentView.swift:252`, but the test name still says they are missing.
- `SmithersClientTests.swift` tests SSE behavior through a copied helper parser rather than the production `sseStream` implementation. This misses trimming, reconnect, URLSession, and dispatch behavior.
- `CodexBridgeLifecycle` is tested, but the real FFI bridge behavior around `codex_send`, `codex_cancel`, failability, callback lifetime, and deinit/destroy is not covered with a test double.
- `TerminalViewTests` do not validate unmanaged callback pointer types, terminal tab surface reuse, or clipboard callbacks.
- Persistence tests cover basic survival and deletion, but not updated ordering/grouping after later messages or large histories.
- CWD tests need a policy cleanup around explicit nonexistent paths versus auto-detected fallback paths.

## Code Quality And Visibility

Most implementation is internally scoped by default, which is normal for a Swift executable target with `@testable` tests. There are still opportunities to tighten surface area:

- Keep public API out of feature internals unless another module needs it. Most view helpers, row models, and persistence helpers can remain `internal` or become `private`/`fileprivate` where tests do not need direct access.
- `SessionStore` is carrying navigation tab state, chat session state, persistence, model selection, and agent construction. That is workable for now, but the working-directory bug is a symptom of too much construction policy living in one place. A small session/agent factory would make cwd, model selection, approval mode, and persistence restore behavior easier to test.
- `SessionPersistenceStore` shells out to sqlite synchronously. That implementation is simple but fragile for a GUI app. It is the highest-value cleanup after the functional bugs above.
- `SessionStore.swift:304` emits a compiler warning because `catch let error as CodexModelSelectionError` is always true for that throwing path. Clean this up as part of warning reduction.
- `GUINotifications.swift:198` currently warns about referencing a main actor-isolated static property from a nonisolated context. This is outside the requested file list but surfaced during the review runs and should be fixed before Swift 6 mode tightens.

## Feature Coverage Summary

- Platform app shell: SwiftUI app, app delegate adaptor, activation policy, hidden title bar, unified toolbar, dark color scheme, and minimum window size are implemented in `ContentView.swift`.
- CWD handling: resolver exists and falls back to home for root and invalid paths, but the resolved store cwd is not passed to `AgentService`.
- Codex FFI: bridge, failability, deinit destroy, callback box, logging, module map, header, and link setup are present. Cancellation during create and real FFI callback lifetime are under-tested.
- Smithers transport: CLI, HTTP, SSE, connection check, availability flags, optional server URL, and JJHub methods are present. SSE production behavior and connection-state semantics need stronger tests.
- Ghostty: terminal embedding and C module map are present, but unmanaged callback userdata has a high-risk bug.
- Theme/navigation/session: dark theme, syntax colors, hex color extension, sidebar sections, search, new chat, routing, session management, titles, previews, timestamps, grouping, insertion, UUID ids, keyboard shortcuts, loading/error states, pull-to-refresh, and edge border helper are represented. The main gaps are default title mismatch, collapsed selected route, and persisted timestamp freshness.

## Verification

Commands run during review:

```text
swift test --filter CWDResolverTests
swift test --filter CWDResolverAdditionalTests
swift test --filter SessionStoreTests
swift test --filter TerminalViewTests
swift test --filter AgentServiceTests/testWorkingDirectory
```

Results:

- `CWDResolverTests` passed on rerun. The first run was interrupted by SwiftPM reporting `LogViewerView.swift` changed during the build.
- `CWDResolverAdditionalTests` passed.
- `SessionStoreTests` passed.
- `TerminalViewTests` did not run because SwiftPM reported `AgentService.swift` changed during the build.
- `AgentServiceTests/testWorkingDirectory` failed because `CWDResolver` changed `/tmp/myproject` to the home directory.

Build warnings observed:

- Ghostty link warnings for missing ImGui-related symbols from `libghostty-fat.a`.
- `GUINotifications.swift:198` main actor isolation warning.
- `SessionStore.swift:304` always-true `as CodexModelSelectionError` warning.
- Several ViewInspector and retroactive conformance warnings in tests.
