# Live Run Time-Travel Scrubber and Rewind

## Context

Spec: `.smithers/specs/live-run-devtools-ui.md` §7.

Header frame scrubber for **view-only** time travel, plus a **Rewind**
action that actually mutates the engine.

## Scope

### 1. Frame scrubber

Lives in the header (below or beside the status row).

- Horizontal slider from 1 to `latestFrameNo`.
- Displays: `frame N / M` with small tick marks at notable events
  (task mounts/unmounts).
- Dragging triggers `smithers.getDevToolsSnapshot(runId, frameNo)` and
  swaps the tree to that snapshot.
- Banner below slider when not at latest: *"Viewing frame N of M
  (historical)."* With a "Return to live" button that snaps back to
  latest and re-subscribes to `streamDevTools`.

Interaction is debounced (~50ms) so scrubbing doesn't hammer the RPC.

### 2. Rewind action

Button in the scrubber region, visible only when viewing a historical
frame of a **live** run:

- Click → confirmation dialog: *"Rewind run to frame N? This is
  destructive and cannot be undone."*
- On confirm → call `smithers.jumpToFrame(runId, frameNo, confirm: true)`.
- On success → toast + snap scrubber to latest + resume live mode.
- On error (`UnsupportedSandbox`, `Busy`, etc.) → error banner with the
  reason.

For finished runs: hide the Rewind button (not eligible in v1).

### 3. Store additions

Extend `LiveRunDevToolsStore`:
- `mode: .live | .historical(frameNo: Int)`.
- `latestFrameNo: Int`.
- `scrubTo(frameNo:)` — fetches snapshot, sets mode = historical.
- `returnToLive()` — re-subscribes to stream, sets mode = live.
- `rewind(to frameNo:)` — calls `jumpToFrame`.

In `.historical` mode, `streamDevTools` subscription is paused so incoming
events don't overwrite the view.

### 4. Visual cue

While in `.historical` mode: the entire view has a subtle sepia/desaturated
overlay (low-opacity filter) so the user can't miss that they're not in
live mode.

## Files (expected)

- `FrameScrubberView.swift` (new)
- `RewindConfirmationDialog.swift` (new)
- `LiveRunDevToolsStore.swift` (extend)
- `SmithersClient.swift` — add `jumpToFrame` method.
- `Tests/SmithersGUITests/FrameScrubberTests.swift` (new)

## Acceptance

- Scrubbing re-renders the tree against the scrubbed frame's snapshot.
- Historical mode: stream events buffered, not applied, until returned to
  live.
- Rewind confirmation dismissible; only proceeds on explicit confirm.
- Rewind success snaps to live mode.
- Finished run: Rewind button hidden; scrubber still works.
- Visual desaturation applied in historical mode.

## Blocked by

- smithers/0010 (`getDevToolsSnapshot`).
- smithers/0013 (`jumpToFrame`).
- gui/0074 (store).
- gui/0075 (tree pane — scrubbing re-renders it).
