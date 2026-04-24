# 0179 Ticket Cross-Reference Cleanup

Audit date: 2026-04-24

Scope:
- Existing ticket files `.smithers/tickets/0158-*.md` through `0178-*.md`.
- Deleted working-tree tickets `0151-*.md` through `0157-*.md` read from `HEAD`.
- Current repo state in `/Users/williamcory/gui` plus referenced sibling repo `/Users/williamcory/plue`.

## Summary

Counts below are finding rows, not ticket rows:

- Already done: 14
- Contradictions: 1
- Stale claims: 15
- Orphan references: 0 hard orphans

No hard orphan refs were found after treating the deleted 0151-0157 files as historical inputs from `HEAD`. There are soft orphans in the working tree because 0151-0157 are deleted locally but still referenced by 0158/0173.

Biggest source-of-truth problem: `/Users/williamcory/plue` currently contains conflict markers in source files that many tickets assume are valid implementation files. Examples include `internal/electric/auth.go`, `internal/electric/shapes.go`, `internal/electric/proxy.go`, `internal/routes/flags.go`, `internal/routes/devtools_snapshots.go`, `internal/services/workspace.go`, and `internal/services/workspace_provisioning.go`.

## Cross-Reference Matrix

| Ticket | Status | References | Referenced by |
| --- | --- | --- | --- |
| 0151 user workspaces route | closed pending plue conflict cleanup | 0141, 0135, 0136 | 0158, 0173 |
| 0152 workflow route mismatch | closed | none | 0173 |
| 0153 rate limits not enforced | superseded by 0162 and 0159 F3 | 0105, 0132 | 0158, 0159, 0162 |
| 0154 devtools HTTP handler | open / partial | 0107, 0157 | 0158, 0159 |
| 0155 approvals HTTP handler | open / partial | none | 0158, 0159, 0175 |
| 0156 client a11y identifiers | closed | none | 0173 |
| 0157 feature flags exposed | partial, blocked by plue conflicts | 0107, 0112 | 0158, 0173 |
| 0158 shipped-but-incomplete umbrella | open, stale status block | 0105, 0107, 0110-0112, 0130-0134, 0139, 0145, 0146, 0149, 0151-0157 | 0173 |
| 0159 plue security review | open | 0107, 0110, 0139, 0153 | 0167, 0173 |
| 0160 iOS a11y/UI review | open, one stale finding | none | 0167, 0173 |
| 0161 Zig-Swift FFI audit | open | none | 0173 |
| 0162 rate-limit correctness audit | open | 0153 | none |
| 0163 Electric authz audit | open, partially implemented in conflicted plue files | none | 0167, 0173 |
| 0164 SSH/WS PTY audit | open, host-key finding done | 0102, 0130 | 0167, 0173, 0175 |
| 0165 auth/token lifecycle audit | open, several findings done | none | 0167, 0173, 0175 |
| 0166 libsmithers concurrency audit | open | none | 0171, 0173 |
| 0167 product readiness gap analysis | superseded by narrower tickets, still useful as rollup | 0145, 0146, 0159, 0160, 0163, 0164, 0165 | none |
| 0168 iOS memory/perf review | open | none | 0173 |
| 0169 observability audit | open, approval-audit finding stale | none | none |
| 0170 user repos GET route | closed pending plue conflict cleanup | none | 0173 |
| 0171 PTY retry clock injection | closed | 0166 | 0173 |
| 0172 TestFlight pipeline audit | open, two blockers done | none | 0173 |
| 0173 drift reconciliation plan | open, needs refresh | 0097-0172, 0151-0158 branch, 0158-0172 | none |
| 0174 dead-code cleanup | open | 0115-0118, 0120, 0123, 0124, 0126, 0146 | none |
| 0175 happy-path traceability | open, stale first-break details | 0164 | none |
| 0176 localization readiness | open | none | none |
| 0177 dependency/license audit | open | none | none |
| 0178 Android bootstrap | open, not required for iOS shippability | 0104 | none |

## Findings

| Ticket | Issue type | Finding | Recommended action |
| --- | --- | --- | --- |
| 0151 | already-done | `GET /api/user/workspaces` is registered in plue at `cmd/server/main.go`, but workspace service files contain conflict markers. | Close only after 0173 conflict cleanup verifies plue builds. |
| 0152 | already-done | Canonical `/api/repos/{owner}/{repo}/runs/{id}/cancel|rerun|resume` aliases exist in plue. | Close. |
| 0153 | stale claim | Original “not mounted anywhere” claim is outdated; several mounts exist, but 0162 found correctness bugs and 0159 still flags dispatch limiter bypass. | Supersede with 0162 plus 0159 F3. |
| 0154 | stale claim | `internal/routes/devtools_snapshots.go` now exists, but it has conflict markers and no `RegisterDevtoolsSnapshotRoutes` call was found in `cmd/server/main.go`. | Keep open; update from “no handler” to “handler exists but conflicted/unmounted.” |
| 0155 | stale claim | Current plue approvals route exposes only `POST /approvals/{id}/decide`; no GET/list route was found. | Keep open; narrow to missing list/detail routes. |
| 0156 | already-done | `auth.signin.root`, terminal status identifiers, and `switcher.state` cleanup are present. | Close. |
| 0157 | stale claim | Feature flag keys exist in `flags.go`, but that file contains conflict markers in current plue. | Keep open until 0173 resolves conflicts and route tests pass. |
| 0158 | stale claim | Status says 0154/0155/0157 routing landed, but current plue contradicts that: devtools is conflicted/unmounted, approvals lacks GET/list, flags file is conflicted. | Update status line to partial; do not close. |
| 0158 | stale claim | Context still lists several now-done remediation items as “confirmed incomplete.” | Move old Context under historical notes or delete it after 0173. |
| 0159 | stale claim | Audit says no findings for `GET/POST /approvals*`, but current plue only has POST decide. | Update scope/results to avoid claiming GET approval coverage. |
| 0160 | stale claim | The high “only bottom Back button” finding is outdated; a top toolbar back button now exists. Missing spoken labels remain. | Mark that single finding done; keep the rest open. |
| 0164 | already-done | Host-key pinning is implemented in `workspace_terminal.go` / `workspace_ssh.go`; no `InsecureIgnoreHostKey` path remains in the terminal handler. | Mark host-key finding done; keep route mismatch, protocol, backpressure, and multi-client findings open. |
| 0165 | already-done | `TokenManager.signOut()` now invalidates local state before revocation and cancels in-flight refresh. | Mark F2 done. |
| 0165 | already-done | Keychain storage now uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. | Mark F4 done. |
| 0165 | already-done | `AuthLoader` now prefers bearer auth when `Authorization` is present. | Mark F6 done. |
| 0165 | already-done | The plue authorize handler no longer returns the old headless JSON response; it now performs a browser-native redirect / upstream IdP detour. | Mark the old server-side JSON-response claim done, but keep OAuth open for the redirect URI mismatch below. |
| 0165 | stale claim | Server `/api/oauth2/authorize` is now browser-native, but GUI uses `smithers://oauth2/callback` while plue seed/tests still use `smithers://auth/callback`. | Replace F1 with “redirect URI mismatch between GUI and plue seed.” |
| 0165 / 0175 | contradiction | OAuth client/server redirect URIs are incompatible: GUI sends `smithers://oauth2/callback`; plue first-party client seed registers `smithers://auth/callback`. | Merge into one OAuth follow-up and fix both sides to one URI. |
| 0167 | already-done | First-run onboarding and settings source files now exist. | Mark those pre-beta bullets done/partial; keep legal/account depth as follow-up if needed. |
| 0167 | stale claim | Product-readiness rollup still references older missing surfaces that now exist, while the true blockers shifted to OAuth URI mismatch, plue conflict cleanup, and terminal/session wiring. | Supersede as a rollup with 0175 + this 0179 source of truth. |
| 0169 | already-done | Approval decisions now go through `NewApprovalsServiceWithAudit`; approval audit tests exist. | Mark PLUE-OBS-003 approval-decision portion done; keep revoke-flow audit check open if not verified. |
| 0170 | already-done | `GET /api/user/repos` exists in plue and is routed at `cmd/server/main.go`. | Close after plue conflict cleanup/build. |
| 0171 | already-done | `RuntimePTYTransport` now accepts an injected `Clock`, and tests use `ManualClock`; no wall-clock retry waits remain. | Close. |
| 0172 | already-done | `ios/Sources/SmithersiOS/PrivacyInfo.xcprivacy` exists and declares UserDefaults plus required native API reasons. | Mark privacy-manifest blocker done. |
| 0172 | already-done | `Assets.xcassets/AppIcon.appiconset` exists with iPhone/iPad/marketing icon wells and is in the Xcode project resources. | Mark app-icon blocker done. |
| 0172 | stale claim | Workflow still selects Xcode 15.4, `SKIP_UPLOAD=1` still requires App Store Connect API fields, and clean-runner native artifact setup is still unresolved. | Keep 0172 open with only remaining TestFlight blockers. |
| 0173 | stale claim | Plan predates 0174-0178 and misses the current committed conflict-marker problem in plue. | Update 0173 or supersede it with a fresh drift cleanup ticket. |
| 0175 | stale claim | It says plue list/detail/decide approval routes are registered; current plue only registers decide. | Update step 9/10 trace. |
| 0175 | stale claim | The first OAuth break is no longer simply “authorize returns JSON/invalid client id”; plue now seeds `smithers-ios`, but GUI/plue redirect URIs disagree. | Update first-break section to the redirect mismatch. |
| 0178 | stale claim | Android remains out of the current iOS rollout; it is not part of the minimum shippability list. | Keep open as product expansion, not release blocker. |

## Minimum-Viable Shippability List

The fewest ticket buckets that matter for an iOS/TestFlight-capable product slice:

1. **0173 refreshed drift/conflict cleanup**: plue has conflict markers in source files. Nothing depending on plue is shippable until this is fixed.
2. **0165 + 0175 OAuth happy path**: unify GUI/plue redirect URI and verify native PKCE from app launch to stored bearer.
3. **0155 approvals read/list plus 0175 approval emission**: decide works only after rows exist; inbox/listing and agent approval creation are not one coherent path yet.
4. **0164 terminal attachability**: libsmithers still builds `/api/workspace/sessions/{id}/terminal` while plue serves the repo-scoped route; also keep the remaining WS protocol/backpressure items.
5. **0163 / 0159 security blockers**: Electric scope/token issues, workflow SSE repo permission, devtools session binding, and dispatch limiter bypass must be resolved before external users.
6. **0166 runtime lifetime/concurrency**: native runtime/PTY lifetime bugs are high-risk for the iOS terminal path.
7. **0172 remaining TestFlight blockers**: Xcode 16+ workflow, deterministic native artifacts, signing preflight polish, dSYM retention, and metadata.
8. **0176 + 0177 release compliance**: base localization and GPL/LGPL/license cleanup before App Store-facing distribution.

Not minimum for the first iOS product slice: 0178 Android bootstrap, most 0174 dead-code cleanup, 0168 performance polish, and low-severity 0160 a11y/haptic polish. Keep high/medium accessibility items before GA, but they are not the first shippability break.
