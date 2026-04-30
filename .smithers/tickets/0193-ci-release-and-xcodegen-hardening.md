# 0193 CI Release And XcodeGen Hardening

Audit date: 2026-04-30

## Summary

Local macOS and iOS builds pass, but the project still has release/CI friction: simulator destination drift, XcodeGen drift checks that are sensitive to invocation path, TestFlight dry-run preflight gaps, and diagnostic artifact retention gaps.

## Parallel Ownership

Primary owner writes:

- `.github/workflows/ci.yml`
- `.github/workflows/ios-testflight.yml`
- `ios/scripts/build-and-upload-testflight.sh`
- `ios/RELEASE.md`
- `project.yml` only if required by build settings

Avoid app source files.

## Requirements

- Make CI simulator destinations robust against installed runtime differences. Prefer explicit IDs discovered at runtime or a destination fallback strategy.
- Ensure the XcodeGen drift check is run from the canonical repo root so path normalization does not produce false diffs.
- Make `SKIP_UPLOAD=1` avoid App Store Connect API secret requirements.
- Add signing/profile preflight validation before archive/upload.
- Retain dSYM and export artifacts privately for release jobs.
- Document local dry-run commands and expected environment variables.

## Acceptance Criteria

- [ ] CI can choose an available iPhone simulator instead of hardcoding an unavailable one.
- [ ] XcodeGen regenerate check has a deterministic command and no false path diffs from temporary output.
- [ ] `SKIP_UPLOAD=1` can archive/export without App Store Connect API secrets.
- [ ] TestFlight workflow uploads dSYM artifacts or documents why App Store Connect symbol upload is sufficient.
- [ ] `ios/RELEASE.md` matches the script behavior.

## Verification

```sh
xcodegen generate
git diff --quiet -- SmithersGUI.xcodeproj
xcodebuild -project SmithersGUI.xcodeproj -scheme SmithersiOS -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.6' -configuration Debug CODE_SIGNING_ALLOWED=NO build
SKIP_UPLOAD=1 ./ios/scripts/build-and-upload-testflight.sh
```

The archive command may require local signing inputs; document any skipped local-only step in the ticket closeout.

## Related

- `.smithers/tickets/0172-ios-testflight-pipeline-audit.md`
