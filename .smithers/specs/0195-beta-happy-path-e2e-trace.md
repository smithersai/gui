# 0195 Beta Happy Path E2E Trace

Updated: 2026-05-01

## Scope Decision
- iOS: in scope and required gate.
- macOS remote mode: in scope in this repository; include matching happy-path coverage.
- Terminal: ticket 0188 is shipped in this repo (`ios/Tests/SmithersiOSE2ETests/SmithersiOSE2ETerminalTests.swift` and production terminal identifiers), so the happy path asserts terminal presence instead of gated-copy fallback.

## End-to-End Trace
1. Sign in or restored-auth bypass succeeds.
- User step: launch app through E2E harness with seeded bearer.
- UI assertion: signed-in shell appears; sign-in shell is absent.
- Backend assertion: authenticated workspace list fetch resolves via `/api/user/workspaces` (non-error switcher state).

2. Choose workspace.
- User step: open switcher/sidebar remote list and select seeded workspace.
- UI assertion: seeded row `switcher.row.<workspace_id>` (iOS) / `sidebar.remote.row.<workspace_id>` (macOS) exists and opens detail.
- Backend assertion: workspace row came from seeded local Plue data and remains discoverable through normal list routes.

3. Chat/dispatch path visible.
- User step: open workspace detail chat surface.
- UI assertion: `content.ios.workspace-detail` (iOS) / `content.macos.workspace-detail` (macOS) mounts.
- Backend assertion: detail route requires authenticated workspace/session state from API-backed data.

4. Run discovery, approval decision, and output/log visibility.
- User step: navigate to run/approval/output surfaces in the same signed-in session.
- UI assertion: run, approval, and output/log related surfaces are visible in the existing E2E suites.
- Backend assertion: existing HTTP-backed E2E groups validate run dispatch/discovery, approval decide transitions, and output/log availability:
  - `SmithersiOSE2EWorkflowRunsTests`
  - `SmithersiOSE2EApprovalsFlowTests`
  - `SmithersiOSE2EAgentChatTests`

5. Terminal access.
- User step: open workspace detail terminal area.
- UI assertion: `content.ios.workspace-detail.terminal` and `terminal.ios.surface` mount (iOS); macOS terminal entry remains visible in workspace detail flows.
- Backend assertion: seeded workspace session ID flows through environment, and terminal attach path remains enabled under shipped 0188 behavior.

6. Sign out and verify stale data wipe.
- User step: trigger sign out from signed-in shell.
- UI assertion: sign-in shell returns; signed-in shell unmounts; seeded workspace row no longer appears in signed-out state.
- Backend/cache assertion: no user-scoped session/workspace controls remain visible post-sign-out (no stale authenticated UI state).

## Minimal Seeding Contract
The happy-path suite requires only:
- one user
- one access token
- one repository
- one workspace
- one workspace session (terminal branch)
- one agent session + one approval row (approval branch)

`ios/scripts/seed-e2e-data.sh` keeps this exact set and no extra scenario rows.

## Failure Artifacts
Local run scripts print deterministic artifact locations:
- iOS xcresult: `build/e2e-results-*.xcresult`
- iOS xcodebuild log: `build/e2e-xcodebuild.log`
- macOS xcresult: `build/macos-e2e-results-*.xcresult`
- macOS xcodebuild log: `build/macos-e2e-xcodebuild.log`

CI can upload these same paths as job artifacts.

## One-Command Verification
```sh
./ios/scripts/run-e2e.sh
./macos/scripts/run-e2e.sh
```

## Acceptance Checklist
- [x] A checked-in trace document lists each user step and backend assertion.
- [x] iOS E2E covers sign-in/restored auth bypass, workspace open, agent message send, run discovery, approval decision, run output/log visibility, and sign-out wipe.
- [x] Terminal is included because ticket 0188 shipped; the happy path asserts terminal presence (`content.ios.workspace-detail.terminal`, `terminal.ios.surface`).
- [x] E2E failure artifacts are documented locally via runner output paths (`build/e2e-results-*.xcresult`, `build/e2e-xcodebuild.log`, `build/macos-e2e-results-*.xcresult`, `build/macos-e2e-xcodebuild.log`) for CI upload.
- [x] The test runs against local Plue with one command per platform (`./ios/scripts/run-e2e.sh`, `./macos/scripts/run-e2e.sh`).
