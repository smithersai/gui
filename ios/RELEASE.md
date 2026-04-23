# iOS release & TestFlight runbook (ticket 0125)

This file is the single source of truth for turning the `SmithersiOS`
target into a signed `.ipa` and shipping it to TestFlight.

Ticket 0121 created the iOS target. Ticket 0125 (this doc) makes it
releasable. Feature work continues in 0122/0123/0124.

---

## TL;DR for the owner (first-time setup)

You need to populate **three secrets** in the repo and register the bundle
id with Apple once. After that, every push to `main` produces a signed
TestFlight build automatically.

1. Register the bundle id in App Store Connect: `com.smithers.ios`.
2. Create an App Store Connect API key (Admin / App Manager role).
3. Export your distribution certificate + provisioning profile.
4. Paste six values into GitHub repo secrets (table below).
5. Push to `main`. The `iOS TestFlight` workflow does the rest.

That is it. If a step below is tedious, it is tedious because Apple makes
it tedious — not because this runbook is underspecified.

---

## External prerequisites (you, the human, do these once)

### 1. Apple Developer account + Team ID

- Enroll at <https://developer.apple.com/programs/>. An individual
  account is sufficient for TestFlight; no organization review is needed
  unless/until you ship to the public App Store.
- Your **Team ID** is a 10-character string (for example `ABCDE12345`).
  Find it at
  <https://developer.apple.com/account> → Membership → "Team ID",
  or in the top-right chip of App Store Connect.
- This value goes into the repo secret `APPLE_TEAM_ID`.

### 2. Register the bundle identifier in App Store Connect

- The bundle id is pinned in `project.yml` to **`com.smithers.ios`**.
  If you register a different id in App Store Connect, upload will fail
  with a confusing "No matching apps" error; change `project.yml` to
  match ASC, not the other way around.
- Steps: App Store Connect → Apps → `+` → New App →
  iOS → bundle id = `com.smithers.ios`, SKU = `smithers-ios`.

### 3. Create a TestFlight group

- App Store Connect → your app → TestFlight → Internal Testing →
  `+` → create a group (for example "Smithers internal").
- Invite testers by Apple ID email. Internal testers see builds
  ~5 minutes after the workflow's upload step completes; external
  testers require Beta App Review on the first build only.

### 4. Generate the App Store Connect API key

- Go to <https://appstoreconnect.apple.com/access/api>.
- Click `+`, pick role **App Manager** (or Admin), name it anything you
  want. Click **Generate**.
- The page gives you three values:
  - **Issuer ID** — a UUID shown once at the top of the page.
  - **Key ID** — a 10-char string shown next to the key.
  - **Private key** — a one-time `.p8` file download. Apple will never
    show it again; if you lose it, revoke the key and create a new one.
- These three values become the three `APP_STORE_CONNECT_*` repo secrets
  below. The `.p8` contents go into the secret **as-is, not base64** —
  multi-line PEM text is fine in a GitHub Actions secret.

### 5. Export the distribution signing identity

You need the private key + certificate as a single `.p12`:

1. In Xcode → Settings → Accounts → pick your team → Manage
   Certificates → `+` → "Apple Distribution".
2. Keychain Access on macOS → Certificates → right-click the new
   "Apple Distribution: ${YOUR_TEAM}" entry → Export → choose `.p12`
   and set a password.
3. Base64-encode it for GitHub: `base64 -i Certificates.p12 | pbcopy`.
4. The encoded blob goes in `IOS_SIGNING_P12_BASE64`, the password in
   `IOS_SIGNING_P12_PASSWORD`.

### 6. Export the provisioning profile

1. <https://developer.apple.com/account/resources/profiles/list>
   → `+` → iOS → Distribution → **App Store** → pick bundle id
   `com.smithers.ios` → pick the Apple Distribution certificate from
   step 5 → name it (e.g. "Smithers iOS App Store").
2. Download the `.mobileprovision` file.
3. Base64-encode it: `base64 -i Smithers_iOS_App_Store.mobileprovision | pbcopy`.
4. Put the encoded blob in `IOS_PROVISIONING_PROFILE_BASE64` and the
   human-readable profile name (the one you typed in step 1) in
   `SMITHERS_IOS_PROVISIONING_PROFILE_NAME`.

---

## Repo secrets reference

All secrets live under Settings → Secrets and variables → Actions,
in the `ios-release` environment.

| Secret name | Source | Example shape |
|---|---|---|
| `APPLE_TEAM_ID` | developer.apple.com membership page | `ABCDE12345` |
| `SMITHERS_IOS_PROVISIONING_PROFILE_NAME` | the human-readable name you typed when creating the profile | `Smithers iOS App Store` |
| `APP_STORE_CONNECT_KEY_ID` | ASC → Users and Access → Integrations → Keys | `AB12CD34EF` |
| `APP_STORE_CONNECT_ISSUER_ID` | same page, top of screen | `69a6de7f-...-a4c6` |
| `APP_STORE_CONNECT_API_KEY_P8` | the `.p8` file contents (paste literally, including `-----BEGIN PRIVATE KEY-----` markers) | multi-line PEM |
| `IOS_SIGNING_P12_BASE64` | `base64 -i Certificates.p12` | base64 blob |
| `IOS_SIGNING_P12_PASSWORD` | password you set in Keychain Access export | any string |
| `IOS_PROVISIONING_PROFILE_BASE64` | `base64 -i *.mobileprovision` | base64 blob |

The **minimum three** values the owner typically has to plug in fresh
(the ones not derivable from local tooling) are:

1. `APPLE_TEAM_ID`
2. `APP_STORE_CONNECT_KEY_ID` + `APP_STORE_CONNECT_ISSUER_ID` +
   `APP_STORE_CONNECT_API_KEY_P8` (one API key, three fields).
3. `SMITHERS_IOS_PROVISIONING_PROFILE_NAME`.

The certificate and profile secrets (`IOS_SIGNING_P12_*` and
`IOS_PROVISIONING_PROFILE_BASE64`) are derived from your local
Keychain / developer portal and only change when a cert rotates.

---

## Versioning rules

`project.yml` carries two values for the `SmithersiOS` target:

- `MARKETING_VERSION` — the user-visible version string, mapped to
  `CFBundleShortVersionString`. Example: `0.1.0`. Bump this manually,
  commit to `main`. Semantic versioning: breaking-UX = major, new
  feature = minor, bugfix = patch.
- `CURRENT_PROJECT_VERSION` — the build number, mapped to
  `CFBundleVersion`. Must be a positive integer and must be
  **strictly increasing per bundle id** as far as App Store Connect is
  concerned; if you upload a number less than or equal to one already
  accepted, ASC rejects the build.

The CI workflow (`.github/workflows/ios-testflight.yml`) overrides
`CURRENT_PROJECT_VERSION` with `${GITHUB_RUN_NUMBER}` — the repo-global
monotonic workflow run counter. This means:

- The value in `project.yml` (`1`) is only used for **local** archives
  when you forget to pass `CURRENT_PROJECT_VERSION` on the command
  line. CI always injects the real number.
- Bumping the marketing version is a code change: edit
  `project.yml`, push.
- Bumping the build number is not a code change: it happens on every
  push automatically.

### How to cut a release

1. Edit `project.yml` → `targets.SmithersiOS.settings.base.MARKETING_VERSION`.
2. Commit and push to `main`.
3. The `iOS TestFlight` workflow picks up the push, archives, and
   uploads. Watch the Actions tab for completion (~8 minutes).
4. ~5 minutes later, internal testers see the build in the TestFlight
   app on their devices.

---

## Local signed archive

You can reproduce exactly what CI does on a laptop. Useful when the
CI upload is failing and you need to bisect signing vs. code issues.

### Prerequisites on your machine

- Xcode 15.4 or newer.
- `xcodegen` (`brew install xcodegen`).
- The signing certificate (from step 5 above) imported into your
  login keychain. Verify with
  `security find-identity -p codesigning -v | grep "Apple Distribution"`.
- The `.mobileprovision` file in
  `~/Library/MobileDevice/Provisioning Profiles/` (double-clicking it
  installs it).

### Running it

```sh
# From the repo root. The script re-execs itself with env -u SDKROOT
# -u LIBRARY_PATH -u RUSTFLAGS, so you don't need to scrub the env by
# hand — but if you invoke xcodebuild directly (see the one-liner
# below), you MUST scrub those three variables first.
export DEVELOPMENT_TEAM="ABCDE12345"                       # your Team ID
export PROVISIONING_PROFILE_SPECIFIER="Smithers iOS App Store"
export APP_STORE_CONNECT_API_KEY_ID="AB12CD34EF"
export APP_STORE_CONNECT_ISSUER_ID="69a6de7f-....-a4c6"
export APP_STORE_CONNECT_API_KEY_P8="$(cat ~/.appstoreconnect/private_keys/AuthKey_AB12CD34EF.p8)"
# Optional, only if you want to dry-run without touching TestFlight:
# export SKIP_UPLOAD=1

./ios/scripts/build-and-upload-testflight.sh
```

Artifacts land in `build/ios-archive/` (gitignored via the repo's
existing `build/` rule).

### Raw xcodebuild one-liner (for debugging)

```sh
env -u SDKROOT -u LIBRARY_PATH -u RUSTFLAGS \
    xcodebuild \
        -project SmithersGUI.xcodeproj \
        -scheme SmithersiOS \
        -destination 'generic/platform=iOS' \
        -configuration Release \
        -archivePath build/ios-archive/SmithersiOS.xcarchive \
        MARKETING_VERSION="0.1.0" \
        CURRENT_PROJECT_VERSION="1" \
        DEVELOPMENT_TEAM="ABCDE12345" \
        PROVISIONING_PROFILE_SPECIFIER="Smithers iOS App Store" \
        CODE_SIGN_STYLE=Manual \
        CODE_SIGN_IDENTITY="Apple Distribution" \
        CODE_SIGNING_REQUIRED=YES \
        CODE_SIGNING_ALLOWED=YES \
        archive
```

The **`env -u SDKROOT -u LIBRARY_PATH -u RUSTFLAGS`** prefix is not
optional. macOS shells inherit these from `direnv` / zig dev shells /
rust toolchains, and Xcode silently honors them. If they are set when
`xcodebuild` starts, it can pick up the wrong SDK or linker flags and
produce a broken archive — or worse, a simulator-slice archive that
ASC rejects with a generic "invalid binary" error.

---

## Simulator / unsigned builds (unaffected)

These still work exactly as before; signing is only enforced in the
`Release` configuration.

```sh
# Simulator build (no signing).
env -u SDKROOT -u LIBRARY_PATH -u RUSTFLAGS \
    xcodebuild \
        -project SmithersGUI.xcodeproj \
        -scheme SmithersiOS \
        -destination 'platform=iOS Simulator,name=iPhone 15' \
        -configuration Debug \
        CODE_SIGNING_ALLOWED=NO \
        build

# Device-slice build (no signing). Same command CI's `ios-device-build`
# job runs.
env -u SDKROOT -u LIBRARY_PATH -u RUSTFLAGS \
    xcodebuild \
        -project SmithersGUI.xcodeproj \
        -scheme SmithersiOS \
        -destination 'generic/platform=iOS' \
        -configuration Debug \
        CODE_SIGNING_ALLOWED=NO \
        CODE_SIGNING_REQUIRED=NO \
        build
```

---

## What to expect if a secret is missing

The archive step fails at build-graph planning with:

```
error: "SmithersiOS" requires a provisioning profile. Select a
provisioning profile in the Signing & Capabilities editor.
```

This is the **expected** failure on a fresh checkout where the owner
has not yet configured any of the secrets above. Seeing this message
means the project structure is correct; it is not a code bug.

---

## Resetting a broken signing setup

Things go wrong. Order of escalation:

1. **"no matching provisioning profile found"** — the profile name
   secret does not match what is in the developer portal. Fix:
   update `SMITHERS_IOS_PROVISIONING_PROFILE_NAME` to the exact name
   shown at <https://developer.apple.com/account/resources/profiles/list>.
2. **"no signing certificate … found"** — the `.p12` blob expired or
   is for the wrong team. Fix: rotate per step 5 above, re-export,
   re-upload `IOS_SIGNING_P12_BASE64` and `IOS_SIGNING_P12_PASSWORD`.
3. **"invalid binary" after ASC upload** — usually a version/build
   collision. Fix: bump `MARKETING_VERSION` in `project.yml` OR push
   again so `GITHUB_RUN_NUMBER` advances.
4. **"Your account does not have permission"** on `altool` — the API
   key has the wrong role. Fix: in ASC → Users and Access →
   Integrations → Keys, regenerate with at least App Manager.
5. **Full reset (nuclear)** — revoke all distribution certs in the
   developer portal, delete the provisioning profile, redo step 5 and
   step 6 above, update `IOS_SIGNING_*` and
   `IOS_PROVISIONING_PROFILE_BASE64`. Previously-archived builds in
   TestFlight are not affected.

---

## Out of scope for this ticket

- Universal links (`applinks:` associated domains) — the OAuth2 flow
  uses a custom URL scheme (`smithers://auth/callback`), and
  universal links would require serving an
  `apple-app-site-association` file from plue. Revisit at App Store
  launch.
- App Store (public) submission — TestFlight only.
- Push notifications — no APNs entitlement today.
- Sign in with Apple — not wired into the OAuth2 flow.

See ticket 0101 (rollout plan) for the phasing that gates these.
