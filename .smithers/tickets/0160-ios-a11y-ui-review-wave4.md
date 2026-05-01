# 0160 iOS Accessibility + UI Review — Wave 4

Date: 2026-04-24

Scope reviewed:
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift`
- Workspace switcher additions (`ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift`, `WorkspaceSwitcherView.swift`)
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift`
- Terminal surface (`ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift`, `ios/Sources/SmithersiOS/Terminal/TerminalIOSCellView.swift`, `ios/Sources/SmithersiOS/Terminal/TerminalIOSGhostty.swift`)
- `Shared/Sources/SmithersAuth/SignInView.swift`

## Summary Counts

| Surface | High | Medium | Low | Total |
| --- | ---: | ---: | ---: | ---: |
| Agent chat | 0 | 1 | 1 | 2 |
| Approvals inbox | 0 | 2 | 2 | 4 |
| Workspace switcher | 1 | 3 | 1 | 5 |
| Content shell | 1 | 1 | 2 | 4 |
| Terminal / Ghostty | 0 | 3 | 0 | 3 |
| Sign-in | 0 | 1 | 1 | 2 |
| Total | 2 | 8 | 7 | 17 |

## Agent Chat

### Medium — Chat rows are not read as a single sensible utterance
Surface + file:line: `Agent P` — `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:102`

Issue: `AgentChatMessageRow` uses `.accessibilityElement(children: .contain)`, so VoiceOver steps through the role, timestamp, and message body as separate elements. In a transcript this is noisy and loses context compared with hearing one coherent announcement per message.

Fix suggestion: Make each row an atomic accessibility element with a combined label/value, for example role + timestamp/pending state + message text. Use `.accessibilityElement(children: .ignore)` and set an explicit label/value.

### Low — Error banner styling is easy to miss
Surface + file:line: `Agent P` — `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:30`

Issue: The error banner uses small footnote text in red on a `Color.red.opacity(0.08)` background. That combination is visually subtle on light backgrounds and does not clearly announce itself as an error state.

Fix suggestion: Raise the contrast for the error treatment and prepend a semantic label such as “Error”. A stronger banner/background token or a system destructive callout style would make failures easier to notice.

## Approvals Inbox

### Medium — Refresh button has no spoken label
Surface + file:line: `Agent R` — `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:43`

Issue: The trailing refresh toolbar item is image-only (`arrow.clockwise`) and has no explicit `.accessibilityLabel`. VoiceOver will not get a reliable action name like “Refresh approvals”.

Fix suggestion: Add `.accessibilityLabel("Refresh approvals")` and, if useful, a hint explaining that it reloads pending approvals.

### Medium — Approve and Deny buttons likely miss the 44pt touch-target minimum
Surface + file:line: `Agent R` — `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:143`

Issue: The row action buttons rely on the intrinsic size of bordered buttons inside an `HStack`. There is no minimum height or larger control size, so these controls are likely below the 44pt target on iPhone.

Fix suggestion: Give both buttons a minimum height of 44pt or use a larger control size/padding so each action meets the touch-target requirement.

### Low — Error copy is rendered with low-emphasis styling
Surface + file:line: `Agent R` — `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:61`

Issue: Load errors and inline row errors are rendered as small red or secondary text on plain backgrounds. For an action-blocking surface, those messages are easy to miss and may not meet AA contrast expectations consistently.

Fix suggestion: Promote failures into a higher-contrast error banner/callout style with clearer hierarchy, especially for the list-level load error.

### Low — Destructive denial action has no haptic feedback
Surface + file:line: `Agent R` — `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:149`

Issue: The destructive `Deny` action has no `.sensoryFeedback` or UIKit feedback generator attached.

Fix suggestion: Add warning/destructive haptic feedback when denial is invoked or confirmed.

## Workspace Switcher

### High — Core row content does not support Dynamic Type
Surface + file:line: `Agent Q` — `WorkspaceSwitcherView.swift:155`

Issue: The row uses fixed 16pt, 13pt, and 11pt fonts for the icon, title, repo label, state, and recency text. That means the main workspace list does not scale with the user’s preferred content size.

Fix suggestion: Replace hard-coded sizes with text styles (`.headline`, `.subheadline`, `.caption`, etc.) and use `@ScaledMetric` where a fixed icon/spacing value still needs to grow with Dynamic Type.

### Medium — Refresh button has no spoken label
Surface + file:line: `Agent Q` — `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:61`

Issue: The iOS presenter’s refresh button is image-only and lacks an explicit accessibility label.

Fix suggestion: Add `.accessibilityLabel("Refresh workspaces")` and optionally a hint that it reloads the remote workspace list.

### Medium — Delete is hidden behind a context menu only
Surface + file:line: `Agent Q` — `WorkspaceSwitcherView.swift:189`

Issue: Remote-row deletion is only exposed through `.contextMenu`. On iOS that is hard to discover for VoiceOver and switch-control users, and there is no named accessibility action or swipe action to surface the destructive option.

Fix suggestion: Add `.swipeActions` and/or `.accessibilityAction(named:)` for delete, and expose a hint that deletion is available.

### Medium — Secondary row metadata is both tiny and low-contrast
Surface + file:line: `Agent Q` — `WorkspaceSwitcherView.swift:163`

Issue: Repo, state, and recency metadata are rendered at 11pt in `.secondary`, and the state chip border uses `Color.secondary.opacity(0.3)`. On light backgrounds this is likely below AA for normal text and makes status information visually weak.

Fix suggestion: Use scalable text styles, increase the contrast of secondary metadata, and replace the 30% border with a stronger semantic badge treatment.

### Low — Destructive delete confirmation has no haptic feedback
Surface + file:line: `Agent Q` — `WorkspaceSwitcherView.swift:77`

Issue: The confirmation dialog’s destructive delete path has no tactile feedback.

Fix suggestion: Add warning/destructive sensory feedback when the confirmed delete action fires.

## Content Shell

### High — Workspace detail removes the top escape route and leaves only a bottom Back button
Surface + file:line: `ios/Sources/SmithersiOS/ContentShell.iOS.swift:139`, `ios/Sources/SmithersiOS/ContentShell.iOS.swift:382`

Issue: Once a workspace is opened, the toolbar back button is removed and the only exit control is the bottom `Back` button after the chat and terminal content. That creates a poor VoiceOver navigation path because a user may have to traverse the entire detail surface before reaching the control needed to leave it.

Fix suggestion: Keep a leading toolbar Back/Close control while a workspace detail is open, and reserve the in-content button as a secondary affordance if needed.

### Medium — Back and forward toolbar buttons have no spoken labels
Surface + file:line: `ios/Sources/SmithersiOS/ContentShell.iOS.swift:138`

Issue: Both toolbar navigation buttons are image-only chevrons with identifiers only. VoiceOver does not get explicit names like “Back” and “Forward”.

Fix suggestion: Add `.accessibilityLabel("Back")` and `.accessibilityLabel("Forward")`, plus hints if the navigation model is non-standard.

### Low — Test-only terminal gate text leaks into accessibility order
Surface + file:line: `ios/Sources/SmithersiOS/ContentShell.iOS.swift:368`

Issue: The diagnostic `Text(seededSessionID ?? "no-session")` is visible to accessibility. VoiceOver will encounter raw session IDs or the phrase “no-session”, which is test/debug information rather than useful UI content.

Fix suggestion: Hide this element from accessibility, or gate it behind E2E-only code paths that never ship to real users.

### Low — Destructive sign-out action has no haptic feedback
Surface + file:line: `ios/Sources/SmithersiOS/ContentShell.iOS.swift:125`

Issue: The destructive sign-out button does not emit any sensory feedback.

Fix suggestion: Add warning/destructive feedback on sign-out tap or completion.

## Terminal / Ghostty

Note: the current iOS bridge still mounts `TerminalIOSTextView` in `TerminalIOSRenderer.swift:69`; the Ghostty-specific findings below are latent until `TerminalIOSGhosttyView` is actually selected.

### Medium — Terminal input field has an unclear VoiceOver label
Surface + file:line: `Terminal surface` — `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:192`

Issue: The input field uses the placeholder text `"input"` as its only label. That is not a good spoken description for a blind user trying to understand the control.

Fix suggestion: Add an explicit label such as “Terminal input” and, if useful, a hint that pressing Send appends a newline.

### Medium — Send button likely misses the 44pt touch-target minimum
Surface + file:line: `Terminal surface` — `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:198`

Issue: The send control is a plain bordered button with no minimum size. In the floating input bar it is likely smaller than the 44pt requirement.

Fix suggestion: Increase the button’s tap area with a minimum height/width or a larger control size.

### Medium — Ghostty renderer does not expose a clear accessibility model
Surface + file:line: `Agent T` — `ios/Sources/SmithersiOS/Terminal/TerminalIOSCellView.swift:75`

Issue: `TerminalIOSGhosttyHostView` mirrors terminal text into a transparent, non-interactive `UITextView`, but it does not expose a clear accessibility label/hint for the terminal region and does not implement accessibility scrolling/actions for the backlog. If this renderer is enabled, VoiceOver users will not get a coherent terminal experience.

Fix suggestion: Define an explicit accessibility surface for the terminal, provide a label/value/hint that explains the region, and implement accessibility scroll or named actions so backlog navigation is possible without pan gestures.

## Sign-In

### Medium — Signed-in sign-out control is not marked as destructive and has no feedback
Surface + file:line: `Agent H` — `Shared/Sources/SmithersAuth/SignInView.swift:57`

Issue: The signed-in state renders `Sign out` as a plain bordered button with no destructive role and no sensory feedback. That weakens both the spoken semantics and the tactile affordance of a session-ending action.

Fix suggestion: Mark the button as `.destructive` and add warning/destructive feedback when the action fires.

### Low — Access-denied messaging uses low-emphasis text for critical account state
Surface + file:line: `Agent H` — `Shared/Sources/SmithersAuth/SignInView.swift:115`

Issue: `WhitelistDeniedView` renders the explanatory copy in `footnote` + `.secondary`, which is visually subdued for a blocking account-status message.

Fix suggestion: Raise the emphasis and contrast of the denial copy so the reason for the blocked state is immediately legible.
