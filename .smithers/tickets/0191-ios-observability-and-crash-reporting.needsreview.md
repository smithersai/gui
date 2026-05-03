# 0191 iOS Observability And Crash Reporting

## Needs Review

2026-05-02: Manual diagnostics export exists, but the ticket still requires beta observability decisions: local counters for key flows, tester instructions, and whether automatic remote crash/error reporting is in scope. That crash-reporting decision affects privacy/release posture and needs product/legal input.

Audit date: 2026-04-30

## Summary

macOS has a structured logging facade and file logs, but iOS still mixes `NSLog`, direct `Logger`, and local UI error strings. There is no automatic crash/error reporting path and no local counters for auth failures, chat sends, reconnects, or runtime churn.

## Parallel Ownership

Primary owner writes:

- `AppLogger.swift` refactor or new shared logger file if needed
- `ios/Sources/SmithersiOS/Diagnostics/`
- `ios/Sources/SmithersiOS/Settings/SettingsView.swift` only for diagnostics/telemetry surface
- `TerminalSurface.swift` only for metric emission, not terminal behavior
- shared/iOS tests for logging and diagnostics

Coordinate with ticket 0190 if both edit Settings.

## Requirements

- Make a logging facade available to iOS with consistent subsystem/categories.
- Replace high-value `NSLog`/direct logger calls in iOS/shared runtime paths with the facade.
- Add local counters for auth failures, chat send success/failure, runtime reconnects, PTY attach failures, and feature-flag refresh failures.
- Add diagnostics export that includes sanitized local logs/counters and app/build/runtime metadata.
- Decide and document whether automatic remote crash/error reporting is in scope for beta. If yes, wire the SDK or backend endpoint. If no, make manual export reliable.

## Acceptance Criteria

- [ ] iOS target includes the logging facade or a shared equivalent.
- [ ] Diagnostics bundle includes counters and sanitized recent logs.
- [ ] No token, bearer, refresh token, or Authorization header can appear in exported diagnostics.
- [ ] Tests cover redaction and diagnostic bundle shape.
- [ ] README or iOS release docs describe how testers send diagnostics.

## Verification

```sh
xcodebuild -project SmithersGUI.xcodeproj -scheme SmithersiOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO test
swift test
```

## Related

- `.smithers/tickets/0169-observability-gap-audit.md`
- `.smithers/tickets/0180-privacy-pii-audit.md`
