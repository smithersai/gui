# 0181 - User Testing Readiness Roadmap

Summary as of 2026-04-24: **No, the user cannot test the iOS app on a physical iPhone today** from this checkout because `SmithersiOS` does not currently link for iOS/device or simulator even with signing disabled; the first thing that must ship is the native iOS build/artifact fix, then a signed device build and a reachable backend URL. The OAuth2 app code is no longer the obvious blocker because the local backend has a browser-native authorize route and the seeded client matches `smithers://oauth2/callback`, but the default production host still returns a Vercel deployment 404 for `/api/oauth2/authorize`, so physical testing needs either a fixed deployment or an explicit test backend.

## Section 1: MUST Fix Before User Tests on Physical iPhone

| # | Blocker | Resolves ticket(s) | LoC | User dependency |
|---|---|---|---|---|
| 1 | Make `SmithersiOS` produce an installable iOS build by fixing the native link/artifact wiring that currently pulls MacOSX SDK libraries while targeting iOS. | 0172 | M/L | Pure code/build-system work. |
| 2 | Provide a valid signing path for bundle ID `com.smithers.ios` so the app can be installed on a real iPhone after the build links. | 0172 | S | Requires Apple signing identity, provisioning profile or developer team, and target device registration/trust. |
| 3 | Point the app at a reachable plue backend and verify authorize-to-callback plus `/api/user` works from the phone on that host. | 0165, 0175 | S/M | Requires a deployed or tunneled backend URL and a usable test account; if a verified host already exists, this is mostly configuration. |

## Section 2: SHOULD Fix Before TestFlight External Beta

| # | Item | Resolves ticket(s) | LoC | User dependency |
|---|---|---|---|---|
| 1 | Make the TestFlight pipeline reproducible on a clean runner with Xcode 16+, deterministic native artifact builds, signing preflights, dSYM retention, and `SKIP_UPLOAD` that does not require App Store Connect secrets. | 0172 | L | Requires App Store Connect credentials for real uploads. |
| 2 | Close the normal beta happy path across repo selection, workspace/session discovery, agent chat, runs context, and approval inbox/list/detail behavior. | 0155, 0167, 0175 | L | Pure code once the intended beta workflow is confirmed. |
| 3 | Fix or temporarily gate terminal access by reconciling the libsmithers terminal WebSocket route with plue, retaining runtime sessions for PTY pointers, and avoiding known terminal lifetime/concurrency hazards. | 0164, 0166, 0175 | L | Pure code; product decision needed only if terminal is hidden for beta. |
| 4 | Finish the external-user security fixes: devtools snapshot session binding, workflow dispatch alias rate limit enforcement, approval UUID validation, Electric token-scope checks, inactive-user rejection, and rate-limit correctness. | 0153, 0159, 0162, 0163 | M/L | Pure backend code. |
| 5 | Route production authenticated iOS requests through the refresh-aware token client and make server refresh-token rotation atomic. | 0165, 0167 | M | Pure code. |
| 6 | Update privacy and account-compliance posture with self-service account deletion, accurate App Store privacy labels, retention/deletion decisions, and log/telemetry redaction for PII. | 0180, 0172 | M/L | Requires product/legal decisions and App Store metadata access. |
| 7 | Resolve release compliance around vendored GPL/commercial `cmux`, LGPL go-ethereum exposure, attribution files, and binary/source distribution obligations. | 0177 | S/M | Requires legal or commercial-license decision. |
| 8 | Clean up CI/test drift so status is trustworthy, especially stale Electric tests, macOS Go build-constraint failures, and superseded readiness tickets. | 0163, 0173, 0179 | M | Pure code/test maintenance. |
| 9 | Address the high-impact accessibility and beta-experience issues such as duplicated navigation affordances, missing labels/traits, touch target consistency, and first-run support/contact metadata. | 0160, 0167, 0172 | S/M | Product input for support URLs and beta copy. |

## Section 3: NICE to Have for GA

| # | Item | Resolves ticket(s) | LoC | User dependency |
|---|---|---|---|---|
| 1 | Add a complete base localization catalog and localization workflow before marketing the app beyond a narrow English beta. | 0176 | L | Requires localization/product copy decisions. |
| 2 | Add production-grade observability, crash reporting, local diagnostics export, and audit coverage beyond the minimum App Store/privacy requirements. | 0169, 0180 | M/L | Requires privacy/telemetry product decision. |
| 3 | Improve memory and performance hotspots in devtools screenshots, polling loops, chat rendering, and terminal rendering. | 0168 | M | Pure code. |
| 4 | Harden Ghostty renderer lifecycle and fidelity once terminal is part of the primary GA story. | 0161, 0167 | M | Pure code. |
| 5 | Expand workflow/developer experience polish such as richer run inspection, better snapshot browsing, deeplinks, and notification handoff. | 0167, 0169 | L | Product prioritization; push notifications would require Apple/APNs setup. |
| 6 | Finish lower-priority accessibility, haptics, visual hierarchy, and copy polish after beta usage shows the dominant workflows. | 0160 | S/M | Product/design input. |
| 7 | Remove dead or duplicated code paths once beta behavior settles and coverage can prove the cleanup is safe. | 0174 | S/M | Pure code. |

## Section 4: Definitely Not Blocking for This Initiative

| # | Item | Ticket(s) | Why not blocking |
|---|---|---|---|
| 1 | Android product bootstrap and release planning. | 0178 | This initiative is physical iPhone and iOS beta readiness, so Android belongs to a separate mobile initiative. |
| 2 | Desktop/macOS OAuth loopback, CLI SSH TOFU, ProxyJump, agent forwarding, and local key-storage hardening. | 0164, 0165 | These are desktop or CLI hardening topics, not requirements for installing and smoke-testing the iOS app. |
| 3 | Multi-client shared PTY scrollback and collaborative terminal semantics. | 0164, 0167 | Single-client or gated terminal behavior is enough for early iOS testing if the beta surface is explicit. |
| 4 | Additional languages beyond a base localization pass. | 0176 | Multi-language rollout is GA or market expansion work, not a blocker for initial user testing. |
| 5 | Already-resolved route and client gaps such as `/api/user/workspaces`, workflow cancel/rerun/resume aliases, `/api/user/repos`, feature-flag exposure, accessibility identifiers, and runtime PTY retry clock injection. | 0151, 0152, 0156, 0157, 0170, 0171 | Current code state contains the relevant routes, identifiers, flags, or tests, so these should stay out of the blocker list unless regressions reappear. |
| 6 | Historical umbrella status from earlier blocker summaries. | 0158, 0179 | These were useful cross-references but are now superseded by the current code-state review in this ticket. |
