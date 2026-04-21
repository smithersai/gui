# Live Run Navigation Patch

The live-run widgets are implemented under the `linux/src/class/live_*.zig`
boundary. `main_window.zig` and the generic session wrapper are intentionally
left untouched for P1/K3 to wire.

## Desired Wiring

1. Export/import `LiveRunView` from `linux/src/class/live_run.zig` where session
   classes are assembled.
2. In `SessionWidget.new`, after creating the Smithers session and event stream,
   branch on `SMITHERS_SESSION_KIND_RUN_INSPECT`.
3. For run-inspect sessions, construct:

   ```zig
   const live = try LiveRunView.newForSession(app, priv.session, false, priv.stream, target_id orelse "");
   priv.stream = null;
   self.as(adw.Bin).setChild(live.as(gtk.Widget));
   ```

4. Store the `LiveRunView` in `SessionWidget.Private` so it can be unreffed in
   dispose. Keep session ownership in `SessionWidget`; the live view owns only
   the event stream subscription in this path.
5. Make `SessionWidget.drainEvents()` return immediately when the embedded live
   view is present. `LiveRunView.SessionSubscription` owns stream draining for
   run-inspect sessions and posts updates back through GTK idle callbacks.
6. `MainWindow.openSession(.run_inspect, run_id)` can continue to route through
   `SessionWidget`; selecting a run from the Runs/Dashboard sidebar will then
   render the live run surface automatically.

## Optional Direct Entry

If P1 keeps a dedicated "Live Run" navigation entry, it can call:

```zig
const live = try LiveRunView.new(app, workspace_path, run_id);
```

That path lets `LiveRunView` own both the Smithers session and its event stream.
