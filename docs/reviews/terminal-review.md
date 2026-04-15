# Terminal Feature Review

Review scope: `TERMINAL` feature group, focused on `TerminalView.swift`, Ghostty bridge behavior, `NSViewRepresentable` lifecycle, keyboard and mouse forwarding, clipboard operations, surface lifecycle/free behavior, callback safety, and terminal-related tests under `Tests/SmithersGUITests` and `Tests/SmithersGUIUITests`.

Static review only. Per request, I did not run `swift test`.

## Findings

### High: Ghostty clipboard confirmation is bypassed

`TerminalView.swift:189` installs `confirm_read_clipboard_cb`, but it immediately calls `completeClipboardRequest(... confirmed: true)` at `TerminalView.swift:193` instead of presenting or enforcing a confirmation flow. `TerminalView.swift:195` also receives the `confirm` flag in `write_clipboard_cb` but ignores it and writes to the pasteboard immediately at `TerminalView.swift:199`.

That means terminal-controlled OSC 52 read/write paths can read or modify the macOS clipboard without the confirmation semantics Ghostty is asking the host app to honor. The vendored Ghostty macOS app handles this by posting a confirmation notification for confirm-required reads/writes before completing the request.

Recommendation: split paste/read operations from confirm-required OSC 52 operations. For confirm-required operations, surface a user decision, include the `ghostty_clipboard_request_e` in policy, and only call `ghostty_surface_complete_clipboard_request` with `confirmed: true` after approval. Add tests around the callback policy using a mockable clipboard/confirmation coordinator.

### High: Terminal surfaces retained in the registry have no removal path, so normal tab surfaces do not deinit or free

`TerminalSurfaceRegistry` stores strong `TerminalSurfaceView` references in `views` at `TerminalView.swift:983` and never removes them. Normal terminal tabs use the registry through `TerminalSurfaceRepresentable` at `TerminalView.swift:1011`, so those `TerminalSurfaceView` instances remain strongly retained after the SwiftUI view is removed. Their `deinit` at `TerminalView.swift:283` is therefore not reached, and `ghostty_surface_free(surface)` at `TerminalView.swift:285` is not called for those sessions.

The lifecycle hole is amplified by `close_surface_cb` being a no-op at `TerminalView.swift:204`. If the shell exits or Ghostty requests surface closure, the UI and registry are not told to remove the surface. This leaks Ghostty surfaces, ptys, C strings, event state, and any renderer resources for every tabbed terminal session.

Recommendation: make terminal tabs explicitly closeable and route close events through a `TerminalSurfaceRegistry.remove(sessionId:)` path that calls or permits `ghostty_surface_free`. Wire `close_surface_cb` to the owning session/tab, and add a regression test with a fake registry or fake Ghostty surface that proves removal releases the view.

### High: C callback userdata is unretained and has no validity or main-thread guard

`TerminalView.swift:258` stores `Unmanaged.passUnretained(self).toOpaque()` in the surface config. Clipboard callbacks recover it with `takeUnretainedValue()` at `TerminalView.swift:185` and `TerminalView.swift:191`, then call AppKit pasteboard APIs and `ghostty_surface_complete_clipboard_request` directly.

The userdata shape appears consistent with Ghostty's macOS embedding pattern: wakeup callbacks use app userdata, while clipboard callbacks receive surface userdata. The issue is lifetime and thread safety. There is no coordinator that can reject callbacks for a freed surface, no `@MainActor`/main queue hop around AppKit pasteboard access, and no check that the recovered `TerminalSurfaceView.surface` still points at a live Ghostty surface. Command-backed terminal views are not retained by `TerminalSurfaceRegistry`, so they are particularly exposed if a delayed callback arrives after SwiftUI removes the view.

Recommendation: introduce a retained callback owner or registry token whose validity can be cleared before freeing the surface. Dispatch callback work that touches AppKit or Swift UI state onto the main actor, and make completion no-op if the token has been invalidated.

### Medium: Ghostty app and config objects are never freed

`GhosttyApp` stores `config` from `ghostty_config_new()` at `TerminalView.swift:141` and `app` from `ghostty_app_new()` at `TerminalView.swift:209`, but `deinit` only invalidates the timer at `TerminalView.swift:229`. The singleton comment at `TerminalView.swift:231` explains why this usually lives until process exit, but it also means the embedding code never exercises `ghostty_app_free` or `ghostty_config_free`, and failure paths after `ghostty_config_new()` can leak config state.

Recommendation: add an explicit shutdown path from `applicationWillTerminate` or a lifecycle owner that invalidates the timer, frees the app, and frees the config in the correct order. Tests can cover this with a small protocol wrapper around the Ghostty C API.

### Medium: `NSViewRepresentable` does not actively synchronize SwiftUI layout size

`TerminalSurfaceRepresentable.updateNSView` is empty at `TerminalView.swift:1029`. The implementation relies on `TerminalSurfaceView.setFrameSize` at `TerminalView.swift:352` to call `syncSurfaceBackingMetrics`, while the initial surface creation calls `syncSurfaceBackingMetrics(sendSize: false)` at `TerminalView.swift:278`.

That can leave Ghostty with stale or zero size if SwiftUI does not drive `setFrameSize` as expected. The vendored Ghostty macOS wrapper explicitly uses an outer size value and `updateOSView` to force synchronization because SwiftUI/AppKit resize callbacks can be deferred or skipped on older macOS versions and under layout pressure.

Recommendation: wrap the representable in a `GeometryReader` and pass the intended size into the representable, then synchronize Ghostty size from `updateNSView` when the size changes. Add a live-window test or a small fake surface wrapper to verify resize events update scaled pixel dimensions.

### Medium: Ghostty runtime integration ignores host actions and app focus/keymap changes

`action_cb` returns `false` for all actions at `TerminalView.swift:180`, and `close_surface_cb` ignores close requests at `TerminalView.swift:204`. `GhosttyApp` also never calls `ghostty_app_set_focus` on app activation/resignation or `ghostty_app_keyboard_changed` when the selected keyboard/input source changes.

The embedded surface can render and receive basic input, but Ghostty features that depend on host actions, close requests, focus state, keyboard layout updates, window/tab commands, title changes, and notification-like actions are not integrated. Some keybindings may appear to do nothing because the host action path always declines them.

Recommendation: decide the intended subset of Ghostty behavior for Smithers. At minimum, handle close-surface, app focus, keyboard selection changes, and any action tags that terminal users can trigger from default keybindings.

### Medium: Keyboard input bypasses AppKit text input composition

`TerminalSurfaceView` sends `ghostty_input_key_s` directly in `sendKey` at `TerminalView.swift:738` and always sets `key.composing = false` at `TerminalView.swift:745`. It does not conform to `NSTextInputClient`, does not call `interpretKeyEvents`, and does not expose marked text/preedit handling.

Basic US keyboard input, modifiers, arrows, and control remaps are covered by the direct path, but dead keys, IME composition, Korean/Japanese/Chinese input, marked text, and some alternative keyboard layouts will be fragile. The upstream Ghostty AppKit surface has substantial `NSTextInputClient` handling for this reason.

Recommendation: either port the relevant text input client behavior from the vendored Ghostty surface or clearly limit this integration to non-IME input until a full text-input bridge exists. Add targeted tests for option-as-alt translation, dead keys, and IME/preedit once the bridge is mockable.

### Medium: Clipboard paste behavior is not shell-safe for file URLs and blurs selection vs standard clipboard

`TerminalClipboard.readString(from:)` converts file URLs to raw paths and joins them with spaces at `TerminalView.swift:34`. Paths containing spaces or shell metacharacters will be pasted ambiguously into a shell. The vendored Ghostty pasteboard helper escapes file paths before producing terminal input.

Separately, selection reads fall back to the standard clipboard at `TerminalView.swift:50`, and selection writes mirror content into `.general` at `TerminalView.swift:200`. That makes middle-click/selection semantics surprising: a missing selection can paste the standard clipboard, and selection writes can overwrite the user's standard clipboard.

Recommendation: shell-escape pasted file paths, and keep selection clipboard behavior separate unless there is an explicit product decision to mirror it on macOS.

### Low: Mouse handling swallows fallback behavior and omits parts of Ghostty's AppKit integration

Right and other mouse events call `ghostty_surface_mouse_button` at `TerminalView.swift:392` and `TerminalView.swift:404`, but the return value is ignored. The vendored Ghostty surface bubbles right-click events to `super` when Ghostty does not consume them, preserving context menu behavior. The Smithers bridge also omits pressure/QuickLook handling and focus-only click suppression.

Recommendation: use the `ghostty_surface_mouse_button` return value for right/other clicks and forward unconsumed events to `super`. Decide whether pressure/QuickLook matters for the embedded terminal.

### Low: Command-backed terminals do not have stable surface identity

Normal terminal routes pass `sessionId` and use `TerminalSurfaceRegistry`, but `.terminalCommand` in `ContentView.swift:60` creates `TerminalView(command:workingDirectory:)` without a session id. The representable therefore creates an unregistered surface at `TerminalView.swift:1019`.

This may be acceptable for one-shot hijack commands, but navigating away destroys the command terminal rather than preserving it as a tab/session. The UI tests only validate the placeholder command text in UI-test mode, so there is no coverage for real command terminal persistence.

Recommendation: if hijack/watch terminals are meant to survive navigation, give command terminals explicit ids and registry entries with a close/removal path.

## Coverage Review

`Tests/SmithersGUITests/TerminalViewTests.swift` covers the SwiftUI fallback/error state and a few pure helper policies such as `TerminalKeyForwardingPolicy`. Most of the Ghostty-specific tests are documentation comments or constant/math assertions, for example lifecycle/free notes at `Tests/SmithersGUITests/TerminalViewTests.swift:324`, keyboard notes at `Tests/SmithersGUITests/TerminalViewTests.swift:369`, and mouse notes at `Tests/SmithersGUITests/TerminalViewTests.swift:458`. They do not instantiate a live `TerminalSurfaceView`, do not call the C callbacks, and do not assert arguments passed to Ghostty.

`Tests/SmithersGUIUITests/AgentsChangesTerminalE2ETests.swift:173` through `Tests/SmithersGUIUITests/AgentsChangesTerminalE2ETests.swift:218` run in UI-test placeholder mode. They validate navigation, placeholder presence, and multiple terminal tab labels, but not native Ghostty rendering, pty startup, input, resize, clipboard, close, or deallocation behavior.

`Tests/SmithersGUIUITests/RunInspectorE2ETests.swift:4` checks that a hijack action opens a terminal command placeholder and displays the shell command. It does not verify the command actually launches in a Ghostty surface outside UI-test mode.

`ContentViewTests` and `SidebarViewTests` provide route, label, icon, and menu coverage for terminal destinations. They do not cover the native surface registry, tab close/removal, or per-session surface preservation.

Recommended coverage additions:

- Add a small Swift wrapper/protocol around the Ghostty C functions so tests can assert `ghostty_surface_new`, `ghostty_surface_set_size`, `ghostty_surface_free`, `ghostty_surface_key`, mouse calls, and clipboard completions without linking a real terminal runtime.
- Unit-test clipboard confirmation policy separately from `NSPasteboard`, including `confirm == true`, OSC 52 read/write requests, selection clipboard, standard clipboard, and file URL escaping.
- Add a lifecycle test for `TerminalSurfaceRegistry`: create a session surface, remove it, and assert the fake surface is freed exactly once and callbacks are invalidated.
- Add a live-window integration test target, separate from regular unit tests, for first responder focus, resize/backing scale, local key monitor installation/removal, and mouse coordinate flipping.
- Add at least one non-placeholder UI or integration smoke test that launches a real Ghostty surface in a controlled environment and verifies typed text reaches the shell.

## Verification

No test commands were run. Static review used source inspection only, including the vendored Ghostty macOS implementation as a reference for callback handling, surface lifecycle, resize synchronization, text input, pasteboard, and mouse behavior.
