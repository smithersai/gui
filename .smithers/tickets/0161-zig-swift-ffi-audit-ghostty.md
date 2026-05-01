# 0161 Zig-Swift FFI Audit: ghostty-vt iOS Bridge

## Scope

- Reviewed `ios/Sources/SmithersiOS/Terminal/TerminalIOSGhostty.swift`
- Reviewed `ios/Sources/SmithersiOS/Terminal/TerminalIOSCellView.swift`
- Reviewed vendored `ghostty-vt` C ABI contracts and Zig implementations under:
  - `ghostty/include/ghostty/vt/terminal.h`
  - `ghostty/include/ghostty/vt/render.h`
  - `ghostty/include/ghostty/vt/style.h`
  - `ghostty/src/terminal/c/terminal.zig`
  - `ghostty/src/terminal/c/render.zig`
- Checked `libsmithers/src/core` for ghostty-vt bindings with `rg -n "ghostty" libsmithers/src/core -S` and found no matches.

## Findings

### 1. Medium

- File:line: `ios/Sources/SmithersiOS/Terminal/TerminalIOSGhostty.swift:335`
- Problem:
  `recreateTerminal()` tears down the old handles, then allocates and stores the replacement `ghostty_terminal`, `ghostty_render_state`, `ghostty_render_state_row_iterator`, and `ghostty_render_state_row_cells` directly into object state as each step succeeds. If a later step throws, the function returns without freeing the handles already recreated on this pass.
- Trigger scenario:
  Any partial-construction failure after one of the `*_new` calls succeeds, for example:
  - `ghostty_render_state_new` fails after `ghostty_terminal_new` succeeded
  - `ghostty_render_state_row_iterator_new` fails after terminal + render state succeeded
  - `ghostty_render_state_row_cells_new` fails after the first three allocations succeeded
  - `ghostty_terminal_resize` fails after all four allocations succeeded

  In those cases the error path leaves the newly allocated handles retained in `self` until a later retry or object deinit. That means the `*_new`/`*_free` pairing is not balanced on the throwing path itself, and the wrapper is also left in a partially initialized state (`snapshot()` will immediately fail because one or more stored handles are nil).
- Why this is real:
  The Swift code stores each successful allocation before the next fallible call:
  - terminal stored at `:363`
  - render state stored at `:370`
  - row iterator stored at `:377`
  - row cells stored at `:384`

  But the subsequent `guard` failures at `:367`, `:374`, `:381`, and `:387` just throw. There is no rollback `defer`/cleanup block in `recreateTerminal()`.
- Fix recommendation:
  Allocate into locals only, attach them to `self` only after all `*_new` calls and the initial resize succeed, and free any partially created locals on failure. In Swift terms, use a local rollback path equivalent to Zig `errdefer`.

## Checklist Disposition

- Ownership:
  One issue found in `recreateTerminal()` error handling as above. Outside that path, steady-state ownership is otherwise consistent: `deinit` frees all four long-lived handles, and normal recreate paths nil out old stored handles after freeing them.
- UnsafePointer lifetime:
  No finding. The bridge copies borrowed terminal strings immediately in `terminalString(for:)`, copies grapheme buffers into Swift storage in `graphemeString(from:count:)`, and does not retain raw ghostty pointers across any `await` boundary. The iOS ghostty coordinator is synchronous and `@MainActor`.
- Threading:
  No current finding. The live `TerminalIOSGhostty` instance is owned by `TerminalIOSGhosttyView.Coordinator`, which is `@MainActor` (`TerminalIOSCellView.swift:345`), and `TerminalSurfaceModel` is also `@MainActor` (`TerminalSurface.swift:101`). I did not find a path that accesses the same ghostty terminal from multiple threads.
- Bounds:
  No current finding. Row and cell traversal goes through ghostty’s iterator APIs, and the Zig implementation bounds-checks `row_iterator_next` / `row_cells_next` against slice length before advancing. The Swift renderer also clamps visible rows/columns before indexing the snapshot grid.
- Error propagation:
  Aside from the partial-recreate ownership bug above, null/error returns are handled cleanly. `snapshot()` throws on failed ghostty getters, `render(into:)` falls back to `hostView.snapshot = nil`, and optional metadata/color lookups degrade safely to empty string or default colors where intended.
- Endianness / ABI:
  No finding. The by-value structs used here (`GhosttyTerminalOptions`, `GhosttyTerminalScrollViewport`, sized structs such as `GhosttyRenderStateColors` and `GhosttyStyle`) are imported from the same C headers that declare the ABI, and the Zig side defines matching `extern struct` / tagged-union layouts. I did not find a Swift-side struct layout mismatch.

## Ship Assessment

- Finding counts:
  - Critical: 0
  - High: 0
  - Medium: 1
  - Low: 0
- Absolute production showstopper:
  No. I did not find a deterministic threading race, use-after-free, or ABI mismatch in the shipped call paths. The one issue is a real ownership bug on partial-construction failure, but it is an error-path hardening problem rather than an always-on crash/corruption path.
