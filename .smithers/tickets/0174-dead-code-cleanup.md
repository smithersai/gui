# Dead code cleanup review

## Scope

Reviewed `ios/Sources/`, `Shared/Sources/`, and `libsmithers/src/` for dead-code signals: unreferenced Swift/Zig declarations, stale ticket/TODO comments, commented-out code, deprecated markers, placeholder views, and unused imports.

## Summary

- Findings: 22
- No `@available(*, deprecated)` declarations found in `ios/Sources/` or `Shared/Sources/`.
- No convincing commented-out Swift/Zig code blocks found; the matches were prose comments.
- No unused imports were confirmed with high confidence.
- The exact string `Remote chat shell is not yet available` was not present.

## Findings

1. File: `ios/Sources/SmithersiOS/Terminal/TerminalIOSCellView.swift:309`
   Reason to remove: `TerminalIOSGhosttyView` has no callers. The active iOS terminal bridge still constructs `TerminalIOSTextView` in `TerminalIOSRenderer.swift`, so this CoreGraphics/Ghostty view is compiled but not wired.
   Safe to delete: no. It appears to be unfinished ticket 0146 work; either wire it into `TerminalIOSRendererBridge` or delete it together with the Ghostty VT adapter and build linkage.

2. File: `ios/Sources/SmithersiOS/Terminal/TerminalIOSGhostty.swift:49`
   Reason to remove: `TerminalIOSGhostty` is only referenced by the unused `TerminalIOSGhosttyView`, making the Ghostty VT wrapper transitively dead in current app behavior.
   Safe to delete: no. Same 0146 caveat: safe only if the project abandons the cell renderer path; otherwise it should be wired and tested.

3. File: `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:3`
   Reason to remove: Header says iOS bytes are decoded by `ghostty-vt`, but the live renderer uses `String(data:encoding:)` in `TerminalIOSTextView`.
   Safe to delete: yes. Stale comment only; replacing it with a UITextView/current-renderer note has no runtime effect.

4. File: `ios/Sources/SmithersiOS/ContentShell.iOS.swift:3`
   Reason to remove: File header still says the shell renders a placeholder detail pane, but the file now mounts workspace actions, terminal, agent chat, approvals, workflow runs, and devtools surfaces.
   Safe to delete: yes. Stale comment only.

5. File: `ios/Sources/SmithersiOS/ContentShell.iOS.swift:31`
   Reason to remove: Comment says tickets 0123/0124 will expand the shell once real leaves compile on iOS. Those leaves are now present in this file.
   Safe to delete: yes. Stale comment only.

6. File: `ios/Sources/SmithersiOS/ContentShell.iOS.swift:402`
   Reason to remove: Comment describes a placeholder pane to be replaced by real chat + terminal shell, but the following implementation now hosts those real surfaces.
   Safe to delete: yes. Stale comment only.

7. File: `ios/Sources/SmithersiOS/ContentShell.iOS.swift:445`
   Reason to remove: `WorkspaceDetailPlaceholder` is a stale type name; it is used, but no longer represents a placeholder-only view.
   Safe to delete: no. The type is live via `IOSContentShell`; rename instead of deleting.

8. File: `Shared/Sources/SmithersStore/WorkspaceSessionPresenceProbe.swift:4`
   Reason to remove: Comment says "The iOS terminal placeholder uses this", but the probe now gates the real terminal mount path.
   Safe to delete: yes. Stale comment only.

9. File: `Shared/Sources/SmithersStore/SmithersStore.swift:113`
   Reason to remove: Catch comment still references a placeholder connect path and `TODO(0126)`. `libsmithers/src/core/session.zig` now defaults to `RealTransport`; the comment should be retargeted to actual remaining failure behavior.
   Safe to delete: yes. Stale comment only.

10. File: `Shared/Sources/SmithersStore/WorkspaceSwitcherModel.swift:17`
    Reason to remove: Comment says "0120 fake transport today"; core session creation now defaults to real transport and only tests opt into fake transport.
    Safe to delete: yes. Stale comment only.

11. File: `Shared/Sources/SmithersStore/README.md:37`
    Reason to remove: README says `libsmithers-core` ships fake transport and waits for 0126 to switch over. The core transport was promoted to `RealTransport`.
    Safe to delete: yes. Stale docs only.

12. File: `Shared/Sources/SmithersStore/WorkspaceSwitcherModel.swift:538`
    Reason to remove: `StoreWorkspaceDeleter` has no callers. `IOSContentShell` creates `WorkspaceSwitcherViewModel(fetcher:)` without a deleter, while `WorkspaceSwitcherView` still exposes delete UI.
    Safe to delete: no. This is probably a wiring gap, not disposable code; either wire the deleter into iOS/macOS switcher construction or remove the delete UI and tests together.

13. File: `Shared/Sources/SmithersAuth/FeatureFlagsClient.swift:123`
    Reason to remove: `setMockResponseProvider(_:)` has no callers. Tests already inject `mockResponseProvider` through the initializer.
    Safe to delete: yes. No repo callers; initializer injection covers the same test seam.

14. File: `Shared/Sources/SmithersE2ESupport/E2EEnvironment.swift:52`
    Reason to remove: `DictionaryEnvironmentSource` is public production-target code but has no callers in sources or tests.
    Safe to delete: yes. Move to tests if needed; no current app path depends on it.

15. File: `Shared/Sources/SmithersStore/DevToolsSnapshotsStore.swift:30`
    Reason to remove: `ensureSubscribed(runId:)` / `release(runId:)` have no callers. The comment says RunInspect-style views bind to this, but current iOS devtools uses its own HTTP client.
    Safe to delete: no. It may be the intended shared-store path; decide whether to wire it or retire the store API.

16. File: `Shared/Sources/SmithersStore/RunsStore.swift:37`
    Reason to remove: `pinRun(_:)` and `unpin(_:)` have no callers; baseline `workflow_runs` subscription still works without them.
    Safe to delete: yes, within this app repo. Remove both methods together after confirming no external SwiftPM consumer relies on the public API.

17. File: `libsmithers/src/apprt/gtk.zig:1`
    Reason to remove: Empty placeholder module (`App`/`Surface` structs only), only re-exported by `apprt/apprt.zig`, no repo callers.
    Safe to delete: yes. Remove the re-export at `apprt/apprt.zig:4` in the same cleanup.

18. File: `libsmithers/src/apprt/none.zig:1`
    Reason to remove: Empty placeholder module (`App`/`Surface` structs only), only re-exported by `apprt/apprt.zig`, no repo callers.
    Safe to delete: yes. Remove the re-export at `apprt/apprt.zig:5` in the same cleanup.

19. File: `libsmithers/src/core/ffi.zig:8`
    Reason to remove: Comment still says old `smithers_app_*` / `smithers_client_*` / `smithers_session_*` FFI is `REMOVE-AFTER-0126`, but those exports are still heavily referenced by macOS wrappers and the libsmithers CLI.
    Safe to delete: yes for the stale comment marker only. Not safe to delete the old FFI without migrating macOS/CLI callers.

20. File: `libsmithers/src/core/session.zig:3`
    Reason to remove: Header repeats `REMOVE-AFTER-0126` for the old local-chat/session model, but the compatibility model is still referenced outside the iOS path.
    Safe to delete: yes for the stale comment marker only. Not safe to delete the compatibility code yet.

21. File: `libsmithers/src/core/core.zig:9`
    Reason to remove: Module header still describes the 0120 skeleton scope: one shape, HTTP write skeleton, PTY skeleton, and no real WebSocket. `transport.zig` now documents and implements promoted `RealTransport`.
    Safe to delete: yes. Stale comment block; replace with current RealTransport status.

22. File: `libsmithers/src/core/schema.zig:39`
    Reason to remove: SQL comment says `TODO(0120-followup): mirror additional shapes from 0115-0118`, but the additional tables are already present immediately below it.
    Safe to delete: yes. The TODO should be removed or changed to "add live adapters" if that remains true.

## Top easiest wins

1. Delete/update stale placeholder comments in `ContentShell.iOS.swift`.
2. Delete/update stale fake-transport comments in `SmithersStore.swift`, `WorkspaceSwitcherModel.swift`, and `Shared/Sources/SmithersStore/README.md`.
3. Remove `FeatureFlagsClient.setMockResponseProvider(_:)`; initializer injection already covers it.
4. Remove or move `DictionaryEnvironmentSource` to tests.
5. Remove empty Zig placeholder modules `apprt/gtk.zig` and `apprt/none.zig` plus their re-exports.
