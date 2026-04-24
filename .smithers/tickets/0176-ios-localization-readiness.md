# Ticket 0176 - iOS Localization Readiness Audit

Date: 2026-04-24

Scope reviewed:

- `ios/Sources/SmithersiOS/**/*.swift`
- `Shared/Sources/SmithersAuth/SignInView.swift`

Method: static source/resource audit only. No localization fixes applied.

## Verdict

Not ready for App Store base English localization.

The iOS target has no checked-in `Localizable.xcstrings`, `Base.lproj/Localizable.strings`, or `.stringsdict`, and the audited Swift does not use `NSLocalizedString`, `String(localized:)`, or `LocalizedStringResource`. SwiftUI literal initializers such as `Text("...")` can become localized keys, but there is currently no base resource to carry the English strings, and many user-visible strings are stored or composed as plain `String`, which bypasses automatic SwiftUI literal extraction.

Before App Store submission, do a full `Localizable.xcstrings` pass for the iOS target and route dynamic/model/error copy through catalog-backed localized resources.

## Severity Counts

- Blocker: 1
- High: 3
- Medium: 3
- Low: 0

## Findings

### Blocker - No base localization resource or lookup path exists

Files:

- `Shared/Sources/SmithersAuth/SignInView.swift:22`
- `ios/Sources/SmithersiOS/SmithersApp.swift:176`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:167`

Evidence:

- Resource scan under `ios` found no `.xcstrings`, no `Base.lproj/Localizable.strings`, no `Localizable.strings`, and no `.stringsdict`.
- The audited Swift scope has no `NSLocalizedString`, `String(localized:)`, `LocalizedStringResource`, or explicit `LocalizedStringKey` use.
- Top-level visible strings are source literals only, for example auth, startup validation, access-gate, and navigation titles.

Impact:

The app does not have a base English localization artifact for App Store submission, and translators/tools have no authoritative string inventory.

Fix hint:

Add an iOS-target `Localizable.xcstrings` with English as the source language, include it in the target resources, and run Xcode string extraction/migration. Keep SwiftUI literal keys in the catalog where possible; convert dynamic strings to `String(localized:)` or model properties typed as `LocalizedStringResource`.

### High - First-run, auth, and access-gate copy is hardcoded English

Files:

- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:68`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:69`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:76`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:78`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:84`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:92`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:106`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:129`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:139`
- `Shared/Sources/SmithersAuth/SignInView.swift:22`
- `Shared/Sources/SmithersAuth/SignInView.swift:24`
- `Shared/Sources/SmithersAuth/SignInView.swift:36`
- `Shared/Sources/SmithersAuth/SignInView.swift:44`
- `Shared/Sources/SmithersAuth/SignInView.swift:48`
- `Shared/Sources/SmithersAuth/SignInView.swift:55`
- `Shared/Sources/SmithersAuth/SignInView.swift:57`
- `Shared/Sources/SmithersAuth/SignInView.swift:67`
- `Shared/Sources/SmithersAuth/SignInView.swift:74`
- `Shared/Sources/SmithersAuth/SignInView.swift:113`
- `Shared/Sources/SmithersAuth/SignInView.swift:120`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:167`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:169`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:187`
- `ios/Sources/SmithersiOS/FeatureFlagGate.iOS.swift:190`
- `ios/Sources/SmithersiOS/SmithersApp.swift:197`
- `ios/Sources/SmithersiOS/SmithersApp.swift:199`

Impact:

The first screens users see cannot be localized from a base catalog. This is the highest-risk user-facing area because onboarding, login, denied access, and startup validation all ship visible English strings.

Fix hint:

Extract every first-run/auth/access string into `Localizable.xcstrings`. For onboarding, replace `Step.title`, `Step.message`, and `Step.linkTitle` plain `String` storage with localized resources or stable localization keys, then render with catalog-backed strings.

### High - Main app surfaces have uncataloged labels, titles, empty states, and action copy

Files:

- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:71`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:75`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:210`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:212`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:243`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:248`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:263`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:267`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:278`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:167`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:174`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:242`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:260`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:264`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:270`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:636`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:652`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:662`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:668`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:673`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:35`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:49`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:53`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:103`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:114`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:130`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:133`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:155`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:193`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:198`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:65`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:79`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:106`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:134`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:151`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:168`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:177`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:199`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:270`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:271`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:272`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:276`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:295`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:39`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:47`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:49`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:56`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:58`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:96`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:44`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:57`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:59`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:79`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:83`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:399`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:443`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:38`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:53`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:72`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:87`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:135`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:142`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:156`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:158`
- `ios/Sources/SmithersiOS/Settings/SettingsView.swift:9`
- `ios/Sources/SmithersiOS/Settings/SettingsView.swift:13`
- `ios/Sources/SmithersiOS/Settings/SettingsView.swift:18`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:32`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:33`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:118`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:119`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:138`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:140`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:150`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:204`

Impact:

The functional iOS app is dominated by hardcoded English strings. Even where SwiftUI treats literals as `LocalizedStringKey`, the strings are not in a base catalog today, so the app is not ready for localization review or translation.

Fix hint:

Run extraction after adding `Localizable.xcstrings`, review all generated entries, and assign stable keys for repeated actions such as Retry, Cancel, Close, Send, Sign out, Approve, and Deny. Keep test-only `accessibilityIdentifier` values out of localization.

### High - Model, status, and error strings are plain `String` and bypass SwiftUI literal extraction

Files:

- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:58`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:59`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:60`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:167`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:172`
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift:179`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:12`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:49`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:52`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:54`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:56`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:60`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:316`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:207`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:431`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:434`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:436`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:438`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:634`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:637`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:639`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:688`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:780`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:878`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:880`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:882`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:884`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:306`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:308`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:330`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:482`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:484`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:486`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:203`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:205`
- `ios/Sources/SmithersiOS/Devtools/DevtoolsPanelView.swift:207`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:432`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:434`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:436`

Impact:

These strings are returned from models, enum computed properties, `LocalizedError.errorDescription`, or helper methods and are later rendered with `Text(message)` or passed to custom views. Because they are plain `String`, they do not behave like SwiftUI string literal localization keys and are easy to miss in extraction.

Fix hint:

Use `String(localized: "key", table: "Localizable")` for computed `String` values, or store `LocalizedStringResource`/stable enum keys in view models and convert at the presentation boundary. Keep server-provided data as data, but localize app-authored fallback text and labels.

### Medium - Retry-duration formatting is handrolled and not locale/plural aware

Files:

- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:332`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:346`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:371`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:373`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:378`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:380`

Impact:

`rateLimitMessage` assembles an English sentence and renders compact `s`/`m` units manually. This does not support locale-specific grammar, plural agreement, spacing, or unit presentation.

Fix hint:

Move the whole retry sentence into the string catalog with placeholders. Format the duration with `Duration`/`DateComponentsFormatter` using the current locale, or add plural/unit variants in the string catalog if the product wants spelled-out units.

### Medium - Icon-only toolbar buttons lack localized accessibility labels and physical chevrons will not mirror for RTL

Files:

- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:159`
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:182`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:82`
- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:90`
- `ios/Sources/SmithersiOS/Approvals/ApprovalsInboxView.swift:61`
- `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:86`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:59`

Impact:

These controls render only SF Symbols. VoiceOver can expose symbol-derived names instead of user-intent labels, and `chevron.left`/`chevron.right` encode physical direction instead of semantic back/forward direction for right-to-left layouts.

Fix hint:

Use `Label` with localized text hidden visually, or add catalog-backed `.accessibilityLabel(...)` values such as Back, Forward, Create workspace, and Refresh. Replace physical chevrons with semantic symbols such as `chevron.backward` and `chevron.forward`.

### Medium - Text field prompts/placeholders are hardcoded, including a non-descriptive terminal prompt

Files:

- `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceSwitcherPresenter.swift:248`
- `ios/Sources/SmithersiOS/Repos/RepoSelectorSheet.swift:72`
- `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:89`
- `ios/Sources/SmithersiOS/Terminal/TerminalIOSRenderer.swift:198`

Impact:

Input prompts are user-visible and are read by assistive technologies. They are not in a localization resource today, and `TextField("input", ...)` is too generic for users and translators.

Fix hint:

Add localized prompt strings for workspace title, repository search, chat message, and terminal command input. Prefer a descriptive terminal prompt such as "Command input" or "Terminal input" in the catalog.

## Checklist Notes

- String literals: many `Text`, `Button`, `Label`, `Section`, `ProgressView`, `ContentUnavailableView`, `TextField`, and navigation title literals exist in the audited Swift. Literal SwiftUI strings are potentially localizable keys, but no base resource exists.
- `Localizable.strings`: none found under `ios`; no `NSLocalizedString` calls found in the audited Swift.
- String Catalog: no `.xcstrings` found under `ios`.
- Plurals: no current `N items`, `N approvals`, or `N runs` style labels were found in scope. The retry-duration string still needs locale-aware duration/unit handling.
- Date/number/currency: no currency formatting found. Workflow run dates use `date.formatted(date: .abbreviated, time: .shortened)` at `ios/Sources/SmithersiOS/WorkflowRuns/WorkflowRunsListView.swift:689` and `:781`, which is locale-aware. Chat timestamps use `DateFormatter` date/time styles at `ios/Sources/SmithersiOS/Chat/AgentChatView.swift:357`; acceptable, though `autoupdatingCurrent` would be stricter. The `en_US_POSIX` formatter at `ios/Sources/SmithersiOS/WorkspaceSwitcher/WorkspaceDetailActions.swift:259` parses RFC-style `Retry-After` HTTP dates and should remain protocol-stable rather than user-locale formatted.
- Right-to-left: most `.leading`/`.trailing` uses are semantic SwiftUI directions and are not findings by themselves. The physical chevrons above are the RTL issue found.
- Accessibility labels: `.accessibilityIdentifier(...)` strings are test identifiers and should not be localized. The issue is missing localized labels for icon-only controls.
