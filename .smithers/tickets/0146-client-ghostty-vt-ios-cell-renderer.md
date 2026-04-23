# Client: swap iOS terminal UITextView placeholder for ghostty-vt cell renderer

## Context

Ticket 0123 (C-TERM) landed cross-platform terminal portability
(`TerminalSurface.swift` + `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift`).
The iOS renderer is a **UITextView placeholder** that displays the
latest byte buffer as plain text — no SGR colors, no cursor rendering,
no escape-sequence handling.

Meanwhile ticket 0092 (H-POC-LIBGHOSTTY) proved that
`ghostty-vt.xcframework` exposes the VT-level C API on iOS and cell
buffers can be read deterministically.

## Goal

Replace the iOS UITextView placeholder with a proper cell-buffer
renderer driven by `ghostty-vt.xcframework`'s output. iOS now matches
macOS's terminal fidelity.

## Scope

- Link `ghostty-vt.xcframework` into the iOS target (the
  `GhosttyKit.xcframework` already linked for auth/macOS doesn't export
  the VT symbols — see 0092's architectural finding).
- Replace `TerminalIOSRenderer.swift`'s UITextView approach with a
  CoreGraphics / Metal cell grid renderer that reads the cell buffer
  from ghostty-vt.
- Hardware keyboard input: route key events through `TerminalSurfaceModel.sendInput`.
- Preserve the on-screen input bar as a fallback / for touch input.
- UITest placeholder mode still works.
- Size overhead recorded in README.

## Acceptance criteria

- Rendering parity with macOS for SGR colors + cursor position against
  a known byte fixture (same test fixture 0092 used).
- iOS e2e harness (ticket 0141) terminal scenario shows colored output
  from a seeded `ls -la` run.
- Hardware keyboard test: simulated `"echo hi"` input reaches the
  remote shell and the response renders.
- Binary size delta ≤ 2 MB.

## Dependencies

- 0140 (real WS PTY transport) — without it, the renderer has no real
  bytes to draw.
- 0092 Stage-0 PoC patterns (already shipped).

## Risks / unknowns

- ghostty-vt is Zig; XCFramework packaging is slightly different from
  the `GhosttyKit` we link for macOS chrome.
- Metal vs CoreGraphics: start with CoreGraphics (simpler, good enough
  for 80×24 cells on iPhone); move to Metal only if perf bites.
