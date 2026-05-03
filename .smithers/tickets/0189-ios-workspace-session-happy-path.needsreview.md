# 0189 iOS Workspace Session Happy Path

## Needs Review

2026-05-02: The current iOS detail flow can discover and mount existing repo-scoped agent sessions, but a true production "start/resume agent session for this selected workspace" still depends on backend/product contract clarity. The current plue API creates repo-bound agent sessions and does not expose a workspace-bound assertion path, so adding a start action would risk misleading users about workspace association.

Audit date: 2026-04-30

## Summary

The iOS workspace detail currently mounts useful surfaces, but the beta happy path is still incomplete without E2E seed context: users need to select a repo/workspace, create or resume an agent session, send a message, observe workflow runs, and navigate approvals from real backend state.

## Parallel Ownership

Primary owner writes:

- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift`
- small additions to `ios/Sources/SmithersiOS/ContentShell.iOS.swift` only for routing/session handoff
- tests under `ios/Tests/SmithersiOSTests` and `ios/Tests/SmithersiOSE2ETests`

Avoid terminal attach internals; ticket 0188 owns terminal.

## Requirements

- Provide explicit "create/resume agent session" behavior when a workspace has no selected `agent_session`.
- Remove dependency on `PLUE_E2E_AGENT_SESSION_ID` for normal chat mounting.
- Make workflow runs usable from selected workspace/repo context instead of seeded repo env only.
- Ensure appending a user message follows the documented implicit dispatch contract.
- Give users a visible state while waiting for the resulting workflow run to appear in shapes/SSE.

## Acceptance Criteria

- [ ] A workspace with no agent session offers a production action to start one.
- [ ] A workspace with existing sessions lets the app select or resume one deterministically.
- [ ] Sending a user message does not require an E2E seeded session id.
- [ ] Workflow runs list can load from selected workspace/repo context without `PLUE_E2E_REPO_OWNER` and `PLUE_E2E_REPO_NAME`.
- [ ] Tests cover "message posted, run discovered later" behavior.

## Verification

```sh
xcodebuild -project SmithersGUI.xcodeproj -scheme SmithersiOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

## Related

- `.smithers/specs/ios-and-remote-sandboxes-dispatch-run.md`
- `.smithers/tickets/0175-happy-path-traceability.md`
