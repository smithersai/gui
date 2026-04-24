# Ticket 0172 - iOS TestFlight Pipeline Audit

Date: 2026-04-24
Scope: `ios/scripts/build-and-upload-testflight.sh`, `project.yml`, iOS `Info.plist`, iOS entitlements, iOS GitHub workflows, `Shared/Sources/SmithersAuth`, privacy manifest, app metadata, and release documentation.

## Verdict

Not ready for a first TestFlight upload by only adding Apple secrets.

The signing script and secret names are largely documented, but a clean CI runner is missing required generated/native artifacts, the workflow is pinned to an App Store Connect-incompatible Xcode version, the iOS target has no privacy manifest despite using required-reason APIs, and the target has no iOS app icon asset catalog. Those issues block either archive creation or App Store Connect/TestFlight processing before testers can install the build.

## Severity Counts

- Blocker: 4
- High: 1
- Medium: 4
- Low: 2

## Findings

### Blocker - Clean GitHub runner does not have the required `ghostty-vt.xcframework`

Evidence:

- `project.yml:346` links `ghostty/zig-out/lib/ghostty-vt.xcframework` into `SmithersiOS`.
- `.github/workflows/ios-testflight.yml:53-55` checks out with `submodules: false`.
- The parent repo tracks only the `ghostty` gitlink; `ghostty/zig-out/lib/ghostty-vt.xcframework` is not tracked.
- `ghostty/.gitignore:12` ignores `zig-out/`, so even initializing the submodule would not provide the xcframework.
- `poc/libghostty-ios/scripts/build-xcframework.sh` exists as a PoC builder, but the TestFlight workflow does not run it.

Impact:

The archive step should fail on a fresh runner before signing/export/upload. Supplying Apple secrets will not fix this.

Required action:

Add a deterministic CI step to initialize/build/cache the iOS `ghostty-vt.xcframework`, or publish it as a release artifact that CI downloads before `xcodegen generate` and `xcodebuild archive`. Add a preflight error in the release script so this fails before invoking `xcodebuild`.

### Blocker - Workflow selects Xcode 15.4, but App Store Connect currently requires iOS builds from Xcode 16 or later

Evidence:

- `.github/workflows/ios-testflight.yml:57-58` selects `/Applications/Xcode_15.4.app`.
- Apple App Store Connect Help currently lists iOS apps as requiring "Built using Xcode 16 or later" for uploads to customer distribution or TestFlight: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/
- Local machine currently reports `Xcode 26.3`, but the workflow pins the hosted runner path to Xcode 15.4 when present.

Impact:

Even if the archive succeeds, an Xcode 15.4-produced iOS binary is at risk of App Store Connect rejection in April 2026.

Required action:

Move the release workflow to a runner/image with Xcode 16+ and select that explicitly. Update `ios/RELEASE.md` after the runner choice is settled.

### Blocker - `PrivacyInfo.xcprivacy` is missing while the iOS app uses `UserDefaults`

Evidence:

- No `PrivacyInfo.xcprivacy` or other `.xcprivacy` file is present under the app target.
- `ios/Sources/SmithersiOS/Onboarding/OnboardingCoordinator.swift` uses `UserDefaults.standard`.
- Apple documents `UserDefaults` as a required-reason API that must be declared in `PrivacyInfo.xcprivacy`: https://developer.apple.com/documentation/foundation/userdefaults
- Apple states apps using required-reason APIs without describing them in a privacy manifest are not accepted by App Store Connect: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api

Impact:

App Store Connect can reject processing before the build becomes usable in TestFlight.

Required action:

Add an app-bundled `PrivacyInfo.xcprivacy` declaring `NSPrivacyAccessedAPICategoryUserDefaults` with an approved reason that matches onboarding state persistence. Re-audit if `libsmithers` is linked into iOS, because the Zig runtime uses filesystem/stat-style APIs that may require additional declarations.

### Blocker - iOS app icon asset is not wired

Evidence:

- `project.yml` has no iOS asset catalog source and no `ASSETCATALOG_COMPILER_APPICON_NAME`.
- Generated `SmithersGUI.xcodeproj/project.pbxproj` has `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` for `SmithersiOS`, but there is no app-target `Assets.xcassets/AppIcon.appiconset` resource in the iOS target.
- The only app icon asset catalogs found are in `.build`, `.worktrees`, or `ghostty/macos`, none of which are iOS app target resources.
- Apple requires app icon imagery in an asset catalog for App Store distribution, including the iOS 1024pt App Store well: https://developer.apple.com/documentation/xcode/configuring-your-app-icon

Impact:

The upload is likely to fail validation or produce an obviously placeholder TestFlight build.

Required action:

Add a Smithers iOS `Assets.xcassets` with `AppIcon.appiconset`, include it in the iOS target resources, and keep `ASSETCATALOG_COMPILER_APPICON_NAME` explicit in `project.yml`.

### High - iOS release build does not appear to link `libsmithers` runtime

Evidence:

- `Shared/Sources/SmithersRuntime/SmithersRuntime.swift:15-17` only imports `CSmithersKit` behind `#if canImport(CSmithersKit)`.
- `ios/Sources/SmithersiOS/ContentShell.iOS.swift:483-485` and `:834-851` gate terminal transport on `canImport(CSmithersKit)`.
- The iOS target in `project.yml:287-353` does not set `SWIFT_INCLUDE_PATHS` for `CSmithersKit`, does not link `libsmithers/zig-out/lib/libsmithers.a`, and the TestFlight workflow does not run `zig build libsmithers`.

Impact:

A signed IPA may compile with the runtime path disabled, leaving terminal/session transport unavailable in the TestFlight product. This may be acceptable for a narrow UI smoke TestFlight, but it is not a shippable Smithers workflow app unless that limitation is intentional.

Required action:

Decide whether the first TestFlight build is allowed to ship without `libsmithers` runtime transport. If not, add deterministic iOS `libsmithers` build/link steps, include `CSmithersKit`, and update privacy/dSYM handling for the linked native code.

### Medium - Signing preflight is mostly documented but still incomplete

Evidence:

- `ios/scripts/build-and-upload-testflight.sh:11-30` documents required and optional environment variables.
- `ios/scripts/build-and-upload-testflight.sh:54-67` fails clearly for missing `DEVELOPMENT_TEAM`, `PROVISIONING_PROFILE_SPECIFIER`, and App Store Connect API fields.
- `.github/workflows/ios-testflight.yml:66-115` imports the `.p12` and provisioning profile, and checks only `IOS_SIGNING_P12_BASE64` and `IOS_PROVISIONING_PROFILE_BASE64` for emptiness.
- `IOS_SIGNING_P12_PASSWORD` is not preflighted before `security import`.
- `ios/scripts/build-and-upload-testflight.sh:144-148` hardcodes the export provisioning profile map to `com.smithers.ios`.

Impact:

The first Apple-account setup can still fail late or cryptically when the `.p12` password is absent/wrong, the profile does not match the bundle/team/certificate, or the owner changes the bundle id without updating the script.

Required action:

Before first upload, validate the `.mobileprovision` contents against Team ID, `com.smithers.ios`, distribution profile type, certificate, and entitlements. If the bundle id changes, update `project.yml`, `Info.plist` expectations, `ios/RELEASE.md`, and the hardcoded export profile key.

### Medium - Local-network privacy string is unresolved

Evidence:

- `ios/Sources/SmithersiOS/Info.plist:78-99` ships ATS exceptions for `localhost` and `127.0.0.1`.
- `ios/Sources/SmithersiOS/SmithersApp.swift:50-61` allows `PLUE_BASE_URL` or `SMITHERS_PLUE_URL` to override the production base URL.
- No `NSLocalNetworkUsageDescription` or `NSBonjourServices` key is present.
- Apple says apps that access the local network should include `NSLocalNetworkUsageDescription`: https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy

Impact:

If TestFlight builds are used against LAN/local Plue endpoints, the app may hit local-network permission behavior without a user-facing explanation. If local endpoints are strictly simulator-only, the release plist should not carry those exceptions.

Required action:

Choose one release posture: add a local-network purpose string for TestFlight/local backend testing, or split the localhost ATS exceptions into debug/e2e-only configuration.

### Medium - Symbols are partially wired but not retained outside App Store Connect

Evidence:

- `ios/scripts/build-and-upload-testflight.sh:140-143` exports with `uploadBitcode=false` and `uploadSymbols=true`.
- No workflow step uploads `.dSYM` artifacts, and no third-party crash-symbol upload is configured.
- Apple recommends uploading symbols with TestFlight/App Store builds so crash reports are symbolicated in Xcode Organizer: https://developer.apple.com/documentation/xcode/building-your-app-to-include-debugging-information

Impact:

App Store Connect/Xcode crash symbolication should work if `uploadSymbols=true` is honored, but there is no independent dSYM retention for later reprocessing or a future crash backend.

Required action:

Keep `uploadSymbols=true`; also archive `build/ios-archive/SmithersiOS.xcarchive/dSYMs` as a private workflow artifact or wire the eventual crash service upload.

### Medium - App Store/TestFlight metadata is not prepared

Evidence:

- No top-level `fastlane/` directory is present.
- No app metadata `description.txt` or screenshots directory for iOS App Store/TestFlight review was found.
- `ios/RELEASE.md:50-56` covers creating an internal TestFlight group but not external beta review metadata, screenshots, app privacy answers, or export compliance answers.

Impact:

Internal TestFlight can usually start with less metadata once a build processes, but external testers and App Review are not ready.

Required action:

Prepare App Store Connect metadata outside the repo or add Fastlane metadata later: app description, subtitle, keywords, support/privacy URLs, screenshots, TestFlight beta review notes, export compliance, and app privacy questionnaire answers.

### Low - `SKIP_UPLOAD=1` still requires App Store Connect API secrets

Evidence:

- `ios/scripts/build-and-upload-testflight.sh:63-67` requires App Store Connect API fields before checking `SKIP_UPLOAD` at `:177-180`.
- The script comments advertise `SKIP_UPLOAD` as useful for local dry-runs.

Impact:

Local archive/export dry-runs still require unnecessary API key material.

Required action:

When fixing the script, only require App Store Connect API fields when upload is enabled.

### Low - Versioning is workable, but local archives can collide

Evidence:

- `project.yml:306-307` defaults `MARKETING_VERSION` to `0.1.0` and `CURRENT_PROJECT_VERSION` to `1`.
- `.github/workflows/ios-testflight.yml:117-134` resolves marketing version and uses `GITHUB_RUN_NUMBER` for the build number.
- `ios/scripts/build-and-upload-testflight.sh:69-70` falls back to `GITHUB_RUN_NUMBER` or `1`.
- Apple associates uploads by bundle id and version/build number: https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/

Impact:

CI build numbers are monotonic enough for TestFlight. Local uploads can collide unless the owner manually sets `CURRENT_PROJECT_VERSION` above the last accepted build.

Required action:

For local uploads, always export `CURRENT_PROJECT_VERSION` to a known-high integer. Keep marketing version bumps manual in `project.yml`.

## Checklist Status

1. Signing: Partial. Required env vars and secret names are documented. Missing `.p12` password preflight, profile-content validation, clean-runner native artifact setup, and Xcode 16+ runner selection.
2. Entitlements: Partial. `ios/SmithersiOS.entitlements` contains the default keychain access group. `TokenStore` currently strips empty access group and does not use shared keychain groups. App Groups and Associated Domains are intentionally omitted, which is acceptable only if macOS/iOS sharing and universal links remain out of scope for TestFlight.
3. Info.plist privacy strings: Partial. OAuth scheme and ATS are present. No Bluetooth/camera/microphone/photo usage found. Local-network string is unresolved because release plist contains localhost ATS exceptions and dev/e2e URL overrides.
4. `PrivacyInfo.xcprivacy`: Missing. This is a blocker because iOS code uses `UserDefaults`.
5. Version/build number: Mostly OK in CI. `CFBundleShortVersionString` and `CFBundleVersion` are wired to `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION`; CI uses `GITHUB_RUN_NUMBER`. Local uploads need manual build-number discipline.
6. Bitcode/symbols: Partial. Bitcode disabled is fine for current iOS distribution. `uploadSymbols=true` is set, but dSYMs are not retained as workflow artifacts.
7. App icon/launch screen: Not ready. No iOS app icon asset is wired. Launch screen is an empty `UILaunchScreen` dictionary, acceptable as a technical placeholder but not branded.
8. App Store metadata: Not ready. No Fastlane metadata or screenshots structure found.

## Apple Account Inputs Needed

When the Apple Developer account is ready, the owner must provide:

- Apple Team ID, stored as `APPLE_TEAM_ID`.
- Bundle identifier registered exactly as `com.smithers.ios`, unless the repo is updated everywhere to a different id.
- App Store Connect app record for the iOS app, using that bundle id and a SKU such as `smithers-ios`.
- Apple Distribution certificate with private key exported as a password-protected `.p12`.
- `IOS_SIGNING_P12_BASE64`: base64 of the `.p12`.
- `IOS_SIGNING_P12_PASSWORD`: password used when exporting the `.p12`.
- App Store distribution provisioning profile for `com.smithers.ios`, the same Team ID, the Apple Distribution certificate, and the current entitlements.
- `IOS_PROVISIONING_PROFILE_BASE64`: base64 of that `.mobileprovision`.
- `SMITHERS_IOS_PROVISIONING_PROFILE_NAME`: exact human-readable profile name from the developer portal.
- App Store Connect API key with sufficient role, preferably App Manager or Admin.
- `APP_STORE_CONNECT_KEY_ID`.
- `APP_STORE_CONNECT_ISSUER_ID`.
- `APP_STORE_CONNECT_API_KEY_P8`: literal `.p8` contents, not base64.
- Internal TestFlight group and tester Apple IDs.
- App privacy questionnaire answers and export-compliance answer for encryption/networking before external beta or App Review.

## Validation Performed

- `bash -n ios/scripts/build-and-upload-testflight.sh`
- `plutil -lint ios/Sources/SmithersiOS/Info.plist ios/SmithersiOS.entitlements`
- Static inspection of `project.yml`, generated Xcode project settings, GitHub workflows, release docs, entitlements, plist, iOS source, and tracked files.

No signed archive or upload was attempted because Apple credentials are not present and the requested scope was audit-only.
