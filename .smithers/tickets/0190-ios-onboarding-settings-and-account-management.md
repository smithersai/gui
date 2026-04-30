# 0190 iOS Onboarding Settings And Account Management

Audit date: 2026-04-30

## Summary

External testers need more than a sign-in button. The iOS app needs first-run framing, account identity, support/diagnostics, legal links, and account-management affordances before a credible beta.

## Parallel Ownership

Primary owner writes:

- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift`
- `ios/Sources/SmithersiOS/Settings/SettingsView.swift`
- `Shared/Sources/SmithersAuth/SignInView.swift` only for copy/link integration
- `ios/Sources/SmithersiOS/Diagnostics/DiagnosticsBundle.swift`
- `ios/Sources/SmithersiOS/Info.plist` only for product/privacy strings if needed
- tests under `ios/Tests/SmithersiOSTests`

Avoid auth-token mechanics; ticket 0184/0187 own token behavior.

## Requirements

- Add first-run copy explaining remote sandboxes, account requirement, and expected workspace lifecycle.
- Add Settings account section with signed-in identity when available.
- Add sign-out, support/contact, diagnostics export, build/version, privacy policy, terms, and account deletion handoff.
- Distinguish disabled, unauthorized, backend unavailable, offline/unknown states in the remote access gate.
- Keep copy product-consistent with ticket 0183's naming allowlist.

## Acceptance Criteria

- [ ] Signed-out first-run screen has support/privacy/terms links.
- [ ] Signed-in Settings shows account identity or a clear fallback.
- [ ] Diagnostics bundle can be generated from Settings.
- [ ] Feature flag/backend down state is not presented as "not enabled for your account."
- [ ] Tests cover first-run, signed-in settings, signed-out settings, and backend unavailable copy.

## Verification

```sh
xcodebuild -project SmithersGUI.xcodeproj -scheme SmithersiOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO test
```

## Product Inputs Needed

- Support URL/email
- Privacy policy URL
- Terms URL
- Account deletion policy and URL/API owner
