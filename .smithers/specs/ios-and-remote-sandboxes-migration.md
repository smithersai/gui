# iOS And Remote Sandboxes — Migration Strategy (gui-tree only)

Companion to `ios-and-remote-sandboxes.md` (see "Cut against the current `libsmithers/src/` tree") and `ios-and-remote-sandboxes-execution.md` (D4). Produced by ticket [0100](../tickets/0100-design-migration-strategy.md).

This doc describes **how the current `libsmithers/src/` tree evolves into `libsmithers-core` + deprecated engine bits, per commit, keeping the macOS desktop app building and running at every step.** It is gui-tree-only: cross-repo work (plue shape definitions, Electric docker-compose, desktop-local spec, production FFI landing in 0120) is a prerequisite not a step in the sequence. See Appendix A.

Data migration — specifically "where the existing local SQLite (`recent_workspaces`, `workspace_sessions`, `workspace_chat_sessions`) goes" — is **not** locked here. See §5.

## 1. File-by-file inventory

Classifications:

- **delete** — engine-shaped, a plue equivalent exists; removed during migration.
- **move-to-core** — pure client code; stays Zig, becomes part of `libsmithers-core` (0120).
- **repurpose-in-core** — file stays, but its responsibility changes (e.g. SQLite wrapper becomes the bounded Electric cache backend).
- **split** — parts delete, parts move. Called out inline.

Grep-verifiable against `find libsmithers/src -type f` (37 files total).

| Path | Classification | Reason |
|---|---|---|
| `libsmithers/src/App.zig` | split | App-level glue stays as core session bootstrap; local-only workspace recents + persisted-session restore goes away (plue owns workspaces). |
| `libsmithers/src/apprt/action.zig` | move-to-core | `Action`/`Target` tagged union is apprt contract shared with platform UI; spec Section 4 keeps FFI-action model. |
| `libsmithers/src/apprt/apprt.zig` | move-to-core | Re-export module; mechanically follows whatever its children resolve to. |
| `libsmithers/src/apprt/embedded.zig` | split | FFI exports stay; engine-backed exports (pty/cwd/local persistence) deprecated. Spec: "engine-side portions deprecated." |
| `libsmithers/src/apprt/gtk.zig` | move-to-core | 2-line stub; harmless. Folded into core's apprt layer. |
| `libsmithers/src/apprt/none.zig` | move-to-core | 2-line stub; test/no-op apprt. |
| `libsmithers/src/apprt/structs.zig` | move-to-core | C-ABI structs (String/Error/Bytes/RuntimeConfig/SessionKind/PaletteMode). Core FFI depends on these. |
| `libsmithers/src/client/agents.zig` | delete | Local agent manifest + env-var lookup for CLI shell-outs; plue owns agent sessions (tickets 0114–0115). |
| `libsmithers/src/client/client.zig` | delete | 1263 LOC transport coordinator mixing CLI shell-outs, local devtools SQLite reads, tmux helpers. Replaced wholesale by 0120's Electric/WS/HTTP/SSE runtime. |
| `libsmithers/src/commands/mod.zig` | move-to-core | 2-line re-export. |
| `libsmithers/src/commands/palette.zig` | move-to-core | Pure command resolution; spec: "stays Zig, becomes `libsmithers-core`." |
| `libsmithers/src/commands/slash.zig` | move-to-core | Pure slash-command parser. |
| `libsmithers/src/devtools/ChatOutput.zig` | move-to-core | State machine over byte streams; reads a local SQLite which, post-migration, is the Electric-cache SQLite with a different schema — file itself stays, the query targets change in 0124. |
| `libsmithers/src/devtools/ChatStream.zig` | move-to-core | State-machine driver atop EventStream. |
| `libsmithers/src/devtools/DevToolsClient.zig` | move-to-core | Pure devtools state logic (no PTY, no process spawn). |
| `libsmithers/src/devtools/Snapshot.zig` | move-to-core | Pure snapshot aggregator. |
| `libsmithers/src/devtools/Stream.zig` | move-to-core | Stream adapter to EventStream. |
| `libsmithers/src/ffi.zig` | repurpose-in-core | FFI helpers (allocator, span/dup, string marshalling) stay; the set of exports re-points at the 0120 session-scoped surface. |
| `libsmithers/src/main.zig` | repurpose-in-core | Library root re-export; list of public modules shrinks as `session/*`, `terminal/*`, `client/*`, `workspace/*` drop. |
| `libsmithers/src/models/aggregations.zig` | move-to-core | Pure data aggregation helpers. |
| `libsmithers/src/models/app.zig` | move-to-core | Pure model descriptor list (spec: "`models/app.zig` and sibling model files — pure data"). |
| `libsmithers/src/models/mod.zig` | move-to-core | Pure model descriptor index. |
| `libsmithers/src/persistence/sqlite.zig` | repurpose-in-core | Spec: "repurposed, not deleted." The wrapper stays; its schema swaps from engine-state tables to the bounded Electric cache (0120). |
| `libsmithers/src/session/buffer.zig` | delete | Scrollback-buffer for local PTY replay; plue's `workspace_terminal.go` owns PTY bytes. |
| `libsmithers/src/session/daemon.zig` | delete | `smithers-session-daemon` entry point; remote mode has no local daemon. Binary dropped from iOS target per 0121. |
| `libsmithers/src/session/event_stream.zig` | move-to-core | Generic async event-queue primitive; reused as the core-side event channel. |
| `libsmithers/src/session/fd_passing.zig` | delete | Unix-socket fd passing between daemon and gui process; no remote-mode use. |
| `libsmithers/src/session/foreground.zig` | delete | Polls `/proc` + `ps` to infer foreground process in a PTY; plue owns PTYs. |
| `libsmithers/src/session/native.zig` | delete | Native local-session state machine driving PTY + foreground polling. |
| `libsmithers/src/session/protocol.zig` | delete | JSON-RPC protocol between gui and local daemon. Replaced by plue's HTTP + WS + SSE + Electric. |
| `libsmithers/src/session/pty.zig` | delete | `openpty`/`forkpty` spawn. Spec: "plue already has this via `workspace_terminal.go` + guest-agent PTY." |
| `libsmithers/src/session/server.zig` | delete | 919-LOC daemon server handling fd passing + native-session lifecycle. No remote-mode role. |
| `libsmithers/src/session/session.zig` | split | 0120 rewrites this as the connection-scoped runtime session. The old "fabricate local chat state" logic (see 0120 Context) is deleted; the public `Session = @This()` identity is preserved so the Swift shell's `Smithers.Session.swift` keeps compiling during the dual-path window. |
| `libsmithers/src/terminal/tmux.zig` | delete | Local tmux controller (socket/session name, nvim launch). Plue owns terminal sessions. |
| `libsmithers/src/workspace/cwd.zig` | move-to-core | Pure CWD resolver; `smithers_cwd_resolve` in the FFI (still useful client-side for local-mode display). |
| `libsmithers/src/workspace/manager.zig` | delete | `workspaceFromLaunch` + `RecentWorkspace` for local workspace discovery; plue owns workspaces. Local-mode replacement (if any) lives in the desktop-local spec. |
| `libsmithers/src/workspace/mod.zig` | split | Drops `manager` export (delete); keeps `cwd` export (move-to-core). |

**Row count: 37. File count under `libsmithers/src/`: 37. Match.**

### 1.1 Aggregate totals by classification

- **delete:** 13 (`client/agents.zig`, `client/client.zig`, `session/buffer.zig`, `session/daemon.zig`, `session/fd_passing.zig`, `session/foreground.zig`, `session/native.zig`, `session/protocol.zig`, `session/pty.zig`, `session/server.zig`, `terminal/tmux.zig`, `workspace/manager.zig`, plus `apprt/embedded.zig` engine-portions — counted under split below).
- **move-to-core:** 16.
- **repurpose-in-core:** 3 (`ffi.zig`, `main.zig`, `persistence/sqlite.zig`).
- **split:** 4 (`App.zig`, `apprt/embedded.zig`, `session/session.zig`, `workspace/mod.zig`).

Sum: 13 + 16 + 3 + 4 = 36 rows; `apprt/embedded.zig` is split but listed once, so the inventory table has exactly 37 rows — one per file.

## 2. Dependency graph (gui-internal)

Nodes are individual files or coherent groups. Edges `A → B` read as "B depends on A — A must move/repurpose/delete first or in the same commit." External dependencies (plue shapes, 0120 FFI, desktop-local spec) are prerequisites (§Appendix A), not graph nodes.

```
                             ┌──────────────────────────────┐
                             │ apprt/structs.zig            │  (C-ABI structs)
                             │ apprt/action.zig             │
                             └──────────────┬───────────────┘
                                            │
                                            ▼
                             ┌──────────────────────────────┐
                             │ ffi.zig (helpers)            │  repurpose
                             │ models/{mod,app,aggregations}│  move-to-core
                             │ commands/{mod,slash,palette} │  move-to-core
                             │ workspace/cwd.zig            │  move-to-core
                             │ session/event_stream.zig     │  move-to-core
                             │ apprt/{apprt,gtk,none}.zig   │  move-to-core
                             └──────────────┬───────────────┘
                                            │ (pure, no engine calls — move first)
                                            ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│ [ENGINE SUBTREE — delete]    │   │ devtools/*.zig (5 files)     │ move-to-core
│ session/pty.zig              │   │ — query bindings re-point    │
│ session/foreground.zig       │   │   to Electric cache in 0124  │
│ session/buffer.zig           │   └──────────────┬───────────────┘
│ session/native.zig           │                  │
│ session/protocol.zig         │                  │
│ session/fd_passing.zig       │                  ▼
│ session/server.zig           │   ┌──────────────────────────────┐
│ session/daemon.zig           │   │ persistence/sqlite.zig       │ repurpose
│ terminal/tmux.zig            │   │ — schema swap (engine tables │
│ client/agents.zig            │   │   → Electric cache tables)   │
│ client/client.zig            │   └──────────────┬───────────────┘
│ workspace/manager.zig        │                  │
└──────────────┬───────────────┘                  │
               │ (every caller must route through │
               │  0120 runtime first — DELETE     │
               │  only after callers re-point)    │
               ▼                                  ▼
┌──────────────────────────────────────────────────────────────┐
│ session/session.zig            split  (rewrite; keep symbol) │
│ App.zig                        split  (thin bootstrap)       │
│ apprt/embedded.zig             split  (drop engine exports)  │
│ workspace/mod.zig              split  (drop manager export)  │
│ main.zig                       repurpose (prune re-exports)  │
│ ffi.zig                        repurpose (retarget surface)  │
└──────────────────────────────────────────────────────────────┘
```

**Ordering rules enforced by this graph (gui-internal):**

1. **Pure move-to-core nodes first** — they have no engine dependencies and can be physically relocated (or namespace-aliased) into the emerging `libsmithers-core` module without touching callers.
2. **SQLite schema swap** waits on the devtools query re-point, because `devtools/ChatOutput.zig` + `devtools/Snapshot.zig` read SQLite directly; they must accept the new cache schema before the schema changes under them.
3. **Engine subtree deletion** waits on every caller in `client/client.zig`, `App.zig`, and `session/session.zig` being rewritten to go through the 0120 runtime.
4. **Split nodes** (`App.zig`, `apprt/embedded.zig`, `session/session.zig`, `workspace/mod.zig`, `main.zig`, `ffi.zig`) are always the **last** things touched in each commit that affects them: they're the visible surface the Swift shell binds to, and their identity must survive the dual-path window (§4).

Nothing in this graph moves until the prerequisites in Appendix A are green.

## 3. Sequenced commit plan (gui-side)

Each commit leaves the desktop app **building + running** against the same existing macOS smoke flow (open a local workspace, launch a terminal, run `ls`, send one chat message). "Building" means `zig build && swift build` (the macOS app) green. "Running" means the macOS smoke gate in §7 passes.

Numbering is monotonic and each step lists: **Files changed**, **Rollback plan**, **Desktop compatibility gate**.

> Note on feature-flagging: Every cutover step reads `libsmithers-core`'s `remote_sandbox_enabled` flag (sourced from plue's `/api/feature-flags`, registered by 0112 — see universal check #8). Default **off**. Macos smoke flow runs with flag **off** → legacy path → unchanged. Dual-path window (§4) runs with flag **on** for the remote-only cohort.

### Step 1 — Add the core module seam without moving anything

- **Scope.** Create `libsmithers/src/core/` directory (empty except for a `README.md` explaining it will absorb move-to-core files) and add a `libsmithers-core` build product in `libsmithers/build.zig` that re-exports the current `main.zig`. No file moves yet.
- **Files changed.** `libsmithers/build.zig`, `libsmithers/src/core/README.md`.
- **Rollback.** Delete `libsmithers/src/core/` directory; revert `build.zig`.
- **Desktop compat gate.** `zig build` green; `swift build` of macOS app green (nothing imports `libsmithers-core` yet); macOS smoke flow (§7.2) unchanged.

### Step 2 — Relocate pure models + commands into `core/`

- **Scope.** Physically move `models/`, `commands/`, `workspace/cwd.zig`, `apprt/{apprt,gtk,none,action,structs}.zig`, `session/event_stream.zig` into `libsmithers/src/core/`. Update imports. No behavior changes. `main.zig` re-exports the new paths under their old names for source compatibility.
- **Files changed.** All move-to-core files listed in §1.1; `main.zig`.
- **Rollback.** `git mv` back to old paths; restore old import lines.
- **Desktop compat gate.** `zig build`; unit tests (`zig build test`); macOS smoke flow. FFI symbol list (`nm libsmithers.dylib | grep smithers_`) unchanged (diff-against-previous: 0 added, 0 removed).

### Step 3 — Swap `persistence/sqlite.zig` to dual-schema mode

- **Scope.** `persistence/sqlite.zig` grows a second schema (the Electric cache tables: one per shape in the initial subscription set). Old engine-state tables (`recent_workspaces`, `workspace_sessions`, `workspace_chat_sessions`) remain functional. New entrypoints (`open_cache`, `upsert_row`, `query_rows`) added; old entrypoints unchanged. File stays at current path (its classification is `repurpose-in-core`, not `move-to-core`, so the physical move defers to Step 8).
- **Files changed.** `libsmithers/src/persistence/sqlite.zig`, plus a new test file asserting both schemas coexist.
- **Rollback.** Revert `persistence/sqlite.zig`; delete new test.
- **Desktop compat gate.** Existing persistence tests pass unchanged; new tests assert both schemas coexist; macOS smoke flow.

### Step 4 — Introduce the 0120 runtime session behind a feature flag (stub-only in this commit)

- **Scope.** Add `libsmithers/src/core/runtime.zig` with the 0120 runtime-session skeleton (constructor, destructor, subscribe/unsubscribe/pin/unpin/write/attachPTY signatures returning `not_implemented`). Add FFI exports in `apprt/embedded.zig` gated on the new session type. **No consumer wiring yet.** Reads `remote_sandbox_enabled` from `/api/feature-flags` (0112 prerequisite — Appendix A).
- **Files changed.** `libsmithers/src/core/runtime.zig` (new), `libsmithers/src/apprt/embedded.zig`, `libsmithers/include/smithers.h` (append-only: new symbols, no removals).
- **Rollback.** Delete `core/runtime.zig`; revert `embedded.zig` + `smithers.h` append.
- **Desktop compat gate.** `zig build`; `swift build` (unused new symbols do not break); macOS smoke flow with flag **off** unchanged; flag **on** → runtime constructor returns `not_implemented`, UI shows the "remote mode unavailable" message. FFI symbol diff: net-additions only.

### Step 5 — Route devtools reads through the bounded cache schema (dual-path)

- **Scope.** `devtools/ChatOutput.zig`, `devtools/Snapshot.zig`, `devtools/ChatStream.zig`, `devtools/Stream.zig` accept a cache-DB handle in addition to the legacy devtools-SQLite path. In flag-off mode, the legacy path is used. In flag-on mode, queries run against the Electric cache tables populated by the (stub) runtime from Step 4.
- **Files changed.** The five `devtools/*.zig` files (moved in Step 2 to `core/devtools/`); a new `core/devtools/cache_bindings.zig` mapping Electric shape rows → the devtools state machines' expected schema.
- **Rollback.** Revert the devtools files; delete `cache_bindings.zig`. The legacy-path code remains untouched, so revert is single-commit clean.
- **Desktop compat gate.** macOS smoke flow (flag off) unchanged; devtools unit tests pass in both modes; no new FFI symbols.

### Step 6 — Land the real Electric shape client + WS PTY client inside `core/runtime.zig`

- **Scope.** Stub implementations in `core/runtime.zig` replaced with the real Zig Electric shape client (0093 PoC → production) and WebSocket PTY client (0094 PoC → production). Connects to plue using platform-injected credentials (0106 + 0109 prerequisites — Appendix A). Still flag-gated.
- **Files changed.** `libsmithers/src/core/runtime.zig`, `libsmithers/src/core/electric/` (new subdir), `libsmithers/src/core/wspty/` (new subdir), `libsmithers/src/core/http/` (new subdir for HTTP writes + SSE).
- **Rollback.** Revert `core/runtime.zig` to the stub from Step 4; delete the three new subdirs.
- **Desktop compat gate.** macOS smoke flow (flag off) unchanged. New integration test: flag-on runtime subscribes to a shape against a local plue+Postgres+Electric docker-compose (prerequisite from 0096) and asserts one delta round-trip. Does NOT run in PR CI until 0096 lands as CI infra; runs developer-local until then.

### Step 7 — First cutover: route one non-critical read (workspaces list, flag-on only) through the runtime

- **Scope.** Workspaces-list view in the Swift shell reads from the runtime-backed store when `remote_sandbox_enabled` is on; unchanged local-mode path otherwise. The legacy `App.zig`-owned workspaces list stays intact for flag-off.
- **Files changed.** `macos/Sources/Smithers/Smithers.App.swift` (adapter update — additive), `libsmithers/src/App.zig` (no-op in this commit), `libsmithers/src/apprt/embedded.zig` (optional new workspace-list FFI exposed).
- **Rollback.** Revert the Swift adapter; legacy path resumes owning workspaces. FFI surface stays.
- **Desktop compat gate.** macOS smoke flow (flag off) unchanged. Dual-path parity test: flag-on run populates the same observable state the flag-off run produces, within a fixture-defined set. Enters the dual-path window (§4) — does NOT proceed to Step 8 until the window elapses.

### Step 8 — Schema cutover: Electric cache is now the sole schema in `persistence/sqlite.zig`

- **Scope.** Physically move `persistence/sqlite.zig` → `core/persistence/sqlite.zig`. Remove the legacy engine-state schema (`recent_workspaces`, `workspace_sessions`, `workspace_chat_sessions` table definitions + migration code). Keep the wrapper API; the old tables are no longer created. **Data migration of pre-existing local rows is handled separately** — see §5.
- **Files changed.** `libsmithers/src/persistence/sqlite.zig` → `libsmithers/src/core/persistence/sqlite.zig`; removal of old schema init code; import fix-ups across callers.
- **Rollback.** `git mv` back; restore the deleted schema code. Pre-migration databases still open (schema was additive through Step 3).
- **Desktop compat gate.** `zig build`; persistence tests against both old-DB-open (schema upgrade path) and new-DB-open (fresh install). macOS smoke flow — note: this is the first step where flag-off macOS may notice, because the old tables stop being *created*; however the app's in-memory read of recents doesn't depend on the SQLite tables existing when recents are empty. §5 constraint: existing desktop users' `recent_workspaces` rows must still be readable; the cutover keeps the *read* path intact for those rows (via a compatibility shim in the wrapper that opens pre-existing tables read-only if present).

### Step 9 — Rip out `terminal/tmux.zig`, `session/tmux`-adjacent helpers, `workspace/manager.zig`, `client/agents.zig`

- **Scope.** These files have no consumers after Step 7's rewire + Step 8's schema cutover. Delete them and the lines in `main.zig` / `App.zig` / `workspace/mod.zig` that import them.
- **Files changed.** Delete: `libsmithers/src/terminal/tmux.zig`, `libsmithers/src/workspace/manager.zig`, `libsmithers/src/client/agents.zig`; update: `libsmithers/src/main.zig`, `libsmithers/src/App.zig`, `libsmithers/src/workspace/mod.zig` (drops `manager` export).
- **Rollback.** `git revert` the deletion commit; the files + their imports are restored intact.
- **Desktop compat gate.** `zig build`; macOS smoke flow (flag off). Any Swift code that still referenced these via FFI fails at build time — none expected after Step 7, but a build break here is cheap to catch.

### Step 10 — Rip out the local session daemon subtree (`session/{pty,foreground,buffer,native,protocol,fd_passing,server,daemon}.zig`)

- **Scope.** Delete the eight engine-subtree files. The `smithers-session-daemon` and `smithers-session-connect` binary targets are removed from `libsmithers/build.zig` (also unblocks 0121's iOS target build, which otherwise chokes on these resources).
- **Files changed.** Delete: 8 files under `libsmithers/src/session/` (leaving only `session.zig` + `event_stream.zig` which moved in Step 2). Update `libsmithers/build.zig`.
- **Rollback.** `git revert`; restores the files and the binary targets.
- **Desktop compat gate.** `zig build` (now produces strictly fewer artifacts; verify with artifact listing); macOS smoke flow (flag off) — the smoke flow in flag-off mode must now delegate "launch a terminal" to a desktop-local replacement. Per §Appendix A.c, desktop-local's replacement lands in a **separate spec's** migration step, so the smoke flow's terminal check is **conditionally skipped** for commits 10-onwards until desktop-local lands. This is the one step that trades a portion of the smoke flow for progress; it is deferred until the desktop-local spec's implementation ticket has landed its own terminal path. **Gate: desktop-local spec implementation ≥ Step 1 shipped.** See Appendix A.c.

### Step 11 — Delete the legacy `client/client.zig`

- **Scope.** With all callers rewired through `core/runtime.zig` and all engine-subtree consumers gone, delete `client/client.zig`. Update `main.zig` to drop the `client` re-export. The `smithers_client_t` FFI handle, `smithers_client_new`, `smithers_client_free`, `smithers_client_call`, `smithers_client_stream` are removed from `smithers.h`. **This is the first removing FFI-surface change in the sequence.**
- **Files changed.** Delete: `libsmithers/src/client/client.zig` (and `libsmithers/src/client/` directory if now empty). Update: `libsmithers/src/main.zig`, `libsmithers/src/apprt/embedded.zig`, `libsmithers/include/smithers.h`. Swift adapters: `macos/Sources/Smithers/Smithers.Client.swift` is rewritten or deleted per 0120's end-state.
- **Rollback.** `git revert` the deletion. The Swift adapter rollback restores the `Smithers.Client` shell.
- **Desktop compat gate.** `zig build`; `swift build`; macOS smoke flow (flag off, with Step 10 caveat about terminal path). The `smithers_client_*` symbol removal is an ABI break — per 0120, this is scheduled and the Swift shell has already migrated to the runtime session. If the Swift shell's migration hasn't landed yet, **this step blocks on 0120 Stage-1 commit landing**. Appendix A.d.

### Step 12 — Rewrite `session/session.zig` + `App.zig` as thin bootstraps (split-step conclusion)

- **Scope.** `session/session.zig` keeps its `@This()` symbol and filename (preserves the Swift shell's import); its body is rewritten to a thin adapter over `core/runtime.zig`'s connection-scoped session (0120 contract). `App.zig` is rewritten to a ~50-LOC bootstrap that constructs a runtime session and exposes its lifecycle. The legacy workspace-recents + persisted-session-restore logic (Context from 0120) is deleted.
- **Files changed.** `libsmithers/src/session/session.zig`, `libsmithers/src/App.zig`, `libsmithers/src/apprt/embedded.zig` (drop engine-backed exports, keep runtime-backed ones), `libsmithers/include/smithers.h` (final surface matches 0120), `libsmithers/src/main.zig`, `libsmithers/src/workspace/mod.zig` (drop `manager` now that it's gone).
- **Rollback.** `git revert` the commit. Previous step's legacy logic is restored in one commit. Note: rollback past Step 11 would also require un-deleting `client/client.zig`, so rolling back Step 12 alone returns the app to post-Step-11 state, not the pre-migration baseline.
- **Desktop compat gate.** `zig build`; `swift build`; macOS smoke flow (flag-on target is now the production path; flag-off retains the local-workspace-open behavior). FFI symbol list matches the 0120 contract exactly. This is the exit criterion for the migration.

Total: **12 steps.** All 12 leave the desktop app in a "building + running" state within the caveats called out per step (Steps 10–12 trade parts of the legacy local-terminal flow for progress, gated on desktop-local + 0120).

## 4. Dual-path window

The spec calls for a cutover-with-parity window, not a hard flip. Proposed default:

- **Per migrated read or write** (Steps 7, 11 are the representative gate points): hold the legacy path alive for **at least one successful production release** after the flag-on remote path ships. "Successful" = no rollback-triggering incidents in that release. After the window, the next step proceeds.
- **Gate markers** between Step 7 → Step 8 → Step 9 → Step 10 → Step 11 → Step 12 consume the window. Steps 1–6 (additive, flag-gated, no Swift-side cutover) do NOT consume a window each; they land back-to-back once each passes CI.
- **Shortening the window** requires a named exception in the follow-up commit message and a pointer to the owning rollout doc (`ios-and-remote-sandboxes-rollout.md`, ticket 0101).
- **Lengthening the window** is cheap — flag stays off for affected cohorts; no code change needed.

Mapping to the rollout doc (0101): the window corresponds to the `desktop-remote private → desktop-remote alpha` phase transitions. Each phase transition is one window.

Why this shape: the rollout doc owns cohort sizing and kill-switch policy; the migration doc owns the code-surface order of removal. They compose — rollout says "when", migration says "only in this order".

## 5. Data-migration constraint (NOT a locked plan)

**Constraint.** Existing desktop users must not lose their `recent_workspaces` history. Today that data lives in the local SQLite at the path the runtime config's `recents_db_path` points at (`smithers.h:231`), populated by `App.zig`'s workspace-open path (see `libsmithers/src/App.zig` `RecentWorkspace`).

**What this doc commits to.**

- The Step 8 schema cutover's compatibility shim opens pre-existing `recent_workspaces` rows **read-only** if they exist. They are not migrated into Electric or any other store by this sequence.
- No commit in this sequence **drops** `recent_workspaces` data from a pre-existing user's SQLite.

**What this doc does NOT commit to.**

- Whether `recent_workspaces` continues to live in libsmithers-core's cache SQLite, or moves into a desktop-local engine's own SQLite (see Appendix A.c), or is promoted into plue's Postgres as a user-scoped shape, or is deleted with a user-visible warning at sign-in.
- The export/import mechanism, if any, between the old schema and whichever destination desktop-local chooses.

**Why deferred.** The destination depends on desktop-local's persistence decisions (its separate spec, referenced by the main spec). Prescribing an export/import here would either (a) prejudge that spec, or (b) guarantee rework when that spec lands. This doc locks only the non-destruction property.

**When the follow-up lands.** A short follow-up spec (filename TBD inside the desktop-local track) commits the export/import path. That follow-up is a prerequisite for **removing** the Step 8 compatibility shim — not for any step in this sequence.

## 6. Per-stage rollback checklist

Consolidated from §3 for review convenience. Each item maps one-to-one with a step.

| Step | Rollback action | Blast radius |
|---|---|---|
| 1 | `rm -r libsmithers/src/core/`; revert `build.zig`. | Zero — file tree only. |
| 2 | `git mv` relocated files back; revert imports. | Build-only; no behavior. |
| 3 | Revert `persistence/sqlite.zig` + new test. | Cache tables disappear; legacy tables unaffected. |
| 4 | Delete `core/runtime.zig`; revert `embedded.zig` + `smithers.h` append. | FFI symbol net-removal; Swift side ignores symbols it never called. |
| 5 | Revert the five `devtools/*.zig` files + `cache_bindings.zig`. | Devtools reads revert to legacy path. |
| 6 | Revert `core/runtime.zig` to stub + delete `electric/`, `wspty/`, `http/` subdirs. | Flag-on runtime goes back to `not_implemented`; flag-off unaffected. |
| 7 | Revert `Smithers.App.swift` adapter. | Workspaces list reverts to legacy path. |
| 8 | `git mv` `persistence/sqlite.zig` back; restore legacy schema init. | Pre-existing SQLite DBs still open; no data loss (shim kept reads intact). |
| 9 | `git revert` the deletion commit. | Restores tmux, `workspace/manager.zig`, `client/agents.zig`. |
| 10 | `git revert` the deletion commit. | Restores the eight session-subtree files + daemon/connect binary targets. |
| 11 | `git revert` the deletion commit; restore Swift `Smithers.Client` adapter. | Restores `client/client.zig` + FFI symbols. |
| 12 | `git revert` the commit. | `session.zig` + `App.zig` return to the previous-step state (not the pre-migration baseline — see §3 Step 12). |

Cross-step constraint: rollbacks must be applied in reverse order (can't roll back Step 8 without first rolling back 9–12). Single-step rollback is always clean within that constraint.

## 7. Desktop-app compatibility gates

Applied **before each commit lands.** Each gate is named and invocable.

### 7.1 Automated gates (every step)

- **Zig build green.** `cd libsmithers && zig build` exits 0.
- **Zig unit tests green.** `cd libsmithers && zig build test` exits 0.
- **macOS app build green.** `cd macos && swift build` exits 0.
- **macOS app tests green.** `cd macos && swift test` exits 0.
- **FFI symbol diff reviewed.** `nm libsmithers/zig-out/lib/libsmithers.dylib | grep smithers_ > /tmp/syms-<step>`; compared against previous step. Removals are allowed only on steps explicitly calling them out (Steps 11, 12). Additions are always fine.
- **GTK shell build** (best-effort — separate CI lane; not load-bearing until a later spec revisits Linux).

### 7.2 Manual macOS smoke flow (every step through Step 9)

Ship-or-fail checklist; runs in under 2 minutes. Captured as a runbook in `docs/testing/desktop-smoke.md` (new file dropped alongside Step 1).

1. Launch the macOS app fresh (no prior state).
2. Open an existing local workspace.
3. Launch a new terminal session. Run `ls -la`. Output renders.
4. Open the command palette. Execute a trivial slash command (e.g. `/help` or `/debug-info`).
5. Send one chat message through the devtools surface. Response (or echo) renders.
6. Close the app. Re-open. Workspace is remembered in the recents list.

From Step 10 onwards the terminal check (item 3) is conditional — see §3 Step 10's note and Appendix A.c.

### 7.3 Dual-path parity gate (Steps 7, 11, 12 — entry only)

Before entering the dual-path window for a given step:

- Flag-on run through the §7.2 flow on a developer machine connected to a local plue+Postgres+Electric docker-compose.
- Observe: same workspace list as flag-off, same chat-message round-trip, same terminal byte stream.
- Diff tolerance: timestamps + sort-stability can differ; row count + IDs must not.

## 8. Appendix A — Prerequisites (external to the gui tree)

The steps in §3 assume the following have landed. The migration sequence does **not** wait on them during planning (this doc can be reviewed and approved now), but no step from §3 proceeds until its named prerequisite is green.

**(a) Plue shape definitions for the tables gui reads.**
Covered by tickets **0114** (`agent_sessions`), **0115** (`agent_messages`), **0116** (`workspaces`), **0117** (`workspace_sessions`), **0118** (`agent_parts`). Step 6 is the first commit here that opens a shape end-to-end; blocks until at least one of these has landed on plue's main.

**(b) Plue Electric docker-compose wiring.**
Covered by ticket **0096** (Electric Go consumer PoC outcome — per the main spec, "now landed"). Step 6's integration test harness depends on the docker-compose fragment 0096 produced. Step 7's dual-path parity gate depends on it being runnable developer-local.

**(c) Desktop-local spec decisions.**
Referenced by the main spec as a sibling spec filename (`ios-and-remote-sandboxes-desktop-local.md` — TBD; not authored yet). Step 10's removal of the local session daemon and Step 12's removal of `App.zig`'s local workspace-recents logic wait on the desktop-local spec's implementation step-1 landing (whatever replacement it chooses for local-terminal, local-recents, local-persistence). §5's data-migration compatibility shim removal also waits on this spec.

**(d) `libsmithers-core` production FFI from 0120.**
Ticket **0120** authors the connection-scoped session FFI that Steps 4, 6, 11, 12 consume. No step past Step 6 proceeds without the 0120 FFI surface being frozen on at least one commit on main. The Swift-shell migration (0120 scope, specifically `Smithers.App.swift` / `Smithers.Client.swift` / `Smithers.Session.swift` becoming thin adapters) is what makes Step 11's ABI-removing commit safe.

These four items are the **only** external blockers. In particular: this sequence does **not** wait on iOS productization (ticket 0113 and its splits, 0121–0126), the approval flow (0110), the devtools snapshot surface (0107), or the run shape work (0111). Those ride on top of the migrated core; they are not prerequisites for the migration itself.

## 9. Self-check (D-VAL universal checks applied to this doc)

1. **Reference integrity.** Every cited gui path (`libsmithers/src/*`, `libsmithers/include/smithers.h`, `macos/Sources/Smithers/Smithers.{App,Client,Session}.swift`, sibling specs, tickets 0092–0120) exists. Ticket citations cross-checked against the ticket filenames. `recents_db_path` line citation on `smithers.h:231` matches Read output.
2. **Scope match.** Ticket 0100 Scope bullets — inventory, dependency graph, sequenced commits (≥10), dual-path window, per-stage rollback, desktop-app gates, prerequisites appendix, data-migration constraint (not prescribed). Each has a named section (§1–§8). ✔
3. **RPC / wire format.** None introduced. ✔
4. **Error taxonomy.** None introduced. ✔
5. **Metric presence.** None introduced. ✔
6. **Mock discipline.** N/A; no tests introduced. The doc names the test invocations other tickets own. ✔
7. **Commit / PR hygiene.** Doc-only. The commit lands via the standard flow and cites 0100. ✔
8. **Feature flag gate.** Doc references `remote_sandbox_enabled` sourced from 0112's `/api/feature-flags`; no hardcoded `true`. ✔
9. **Cross-link coherence.** Main spec (`ios-and-remote-sandboxes.md` §Related documents) and execution plan (§D4) gain links to this file (drive-by edits). Tombstoned tickets (0119, 0127–0129, 0137) are not referenced. ✔
10. **No forbidden assumption.** Desktop-local stays called out as sibling-spec-owned (§Appendix A.c + §5). No step assumes desktop-local is in this initiative. ✔

## 10. Related documents

- Main spec: `ios-and-remote-sandboxes.md`.
- Execution plan: `ios-and-remote-sandboxes-execution.md` (D4 points here).
- Independent validation checklist: `ios-and-remote-sandboxes-validation.md`.
- Production-runtime architecture: `.smithers/tickets/0120-client-libsmithers-core-production-runtime.md`.
- Ticket: `.smithers/tickets/0100-design-migration-strategy.md`.
