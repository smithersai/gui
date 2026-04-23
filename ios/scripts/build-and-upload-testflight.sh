#!/usr/bin/env bash
# ios/scripts/build-and-upload-testflight.sh — ticket 0125.
#
# Produces a signed .xcarchive for the SmithersiOS target, exports it to an
# .ipa using App Store distribution, and uploads the .ipa to TestFlight via
# the App Store Connect API.
#
# Designed to run identically on a developer laptop AND on GitHub Actions.
# The only difference is where the inputs come from:
#
#   Inputs (all REQUIRED):
#     DEVELOPMENT_TEAM             Apple Team ID (10 chars, e.g. ABCDE12345).
#     PROVISIONING_PROFILE_SPECIFIER
#                                  Name of the App Store provisioning profile
#                                  (e.g. "Smithers iOS App Store").
#     APP_STORE_CONNECT_API_KEY_ID Key ID from appstoreconnect.apple.com/access/api.
#     APP_STORE_CONNECT_ISSUER_ID  Issuer ID from that same page.
#     APP_STORE_CONNECT_API_KEY_P8 Literal contents of the AuthKey_XXX.p8 file
#                                  (NOT a path — the file contents). CI stores
#                                  this in a secret; locally you can do
#                                  `export APP_STORE_CONNECT_API_KEY_P8="$(cat
#                                  ~/.appstoreconnect/AuthKey_XXXX.p8)"`.
#
#   Optional inputs:
#     MARKETING_VERSION            e.g. 0.1.0. Default: read from project.yml.
#     CURRENT_PROJECT_VERSION      Monotonic integer. Default: ${GITHUB_RUN_NUMBER:-1}.
#     EXPORT_METHOD                app-store | ad-hoc | development.
#                                  Default: app-store.
#     SKIP_UPLOAD                  If non-empty, skip the TestFlight upload
#                                  step (useful for local dry-runs).
#
# The script writes:
#   build/ios-archive/SmithersiOS.xcarchive
#   build/ios-archive/SmithersiOS.ipa
#   build/ios-archive/ExportOptions.plist
#
# Exit codes:
#   0  — archive exported (and uploaded, unless SKIP_UPLOAD).
#   1  — missing input.
#   2  — xcodebuild archive failed (usually signing/profile mismatch).
#   3  — xcodebuild export failed.
#   4  — altool/notarization upload failed.

set -euo pipefail

# The unenv gotcha: macOS environments often ship with SDKROOT, LIBRARY_PATH,
# or RUSTFLAGS set by shell profiles. Those variables change which SDK
# xcodebuild picks up and can produce silently-wrong simulator-slice
# archives. Strip them unconditionally before invoking xcodebuild.
if [ -z "${SMITHERS_SKIP_ENV_SCRUB:-}" ]; then
    exec env -u SDKROOT -u LIBRARY_PATH -u RUSTFLAGS SMITHERS_SKIP_ENV_SCRUB=1 "$0" "$@"
fi

require() {
    local name="$1"
    if [ -z "${!name:-}" ]; then
        echo "error: required input \$$name is not set." >&2
        echo "       See ios/RELEASE.md for how to plumb it in." >&2
        exit 1
    fi
}

require DEVELOPMENT_TEAM
require PROVISIONING_PROFILE_SPECIFIER
require APP_STORE_CONNECT_API_KEY_ID
require APP_STORE_CONNECT_ISSUER_ID
require APP_STORE_CONNECT_API_KEY_P8

MARKETING_VERSION="${MARKETING_VERSION:-$(awk '/MARKETING_VERSION:/ {gsub(/["'\'']/, "", $2); print $2; exit}' project.yml)}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-${GITHUB_RUN_NUMBER:-1}}"
EXPORT_METHOD="${EXPORT_METHOD:-app-store}"

echo "→ Ticket 0125 iOS release build"
echo "  MARKETING_VERSION       = ${MARKETING_VERSION}"
echo "  CURRENT_PROJECT_VERSION = ${CURRENT_PROJECT_VERSION}"
echo "  DEVELOPMENT_TEAM        = ${DEVELOPMENT_TEAM}"
echo "  PROVISIONING_PROFILE    = ${PROVISIONING_PROFILE_SPECIFIER}"
echo "  EXPORT_METHOD           = ${EXPORT_METHOD}"

BUILD_DIR="build/ios-archive"
ARCHIVE_PATH="${BUILD_DIR}/SmithersiOS.xcarchive"
EXPORT_PATH="${BUILD_DIR}"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"

mkdir -p "${BUILD_DIR}"

# Regenerate the Xcode project so project.yml is the single source of truth.
if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is not installed. 'brew install xcodegen'." >&2
    exit 1
fi
xcodegen generate

# -------------------------------------------------------------------------
# 1. Archive.
# -------------------------------------------------------------------------
echo "→ Archiving SmithersiOS..."
set +e
xcodebuild \
    -project SmithersGUI.xcodeproj \
    -scheme SmithersiOS \
    -destination 'generic/platform=iOS' \
    -configuration Release \
    -archivePath "${ARCHIVE_PATH}" \
    MARKETING_VERSION="${MARKETING_VERSION}" \
    CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION}" \
    DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM}" \
    PROVISIONING_PROFILE_SPECIFIER="${PROVISIONING_PROFILE_SPECIFIER}" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    archive
ARCHIVE_STATUS=$?
set -e
if [ ${ARCHIVE_STATUS} -ne 0 ]; then
    echo "error: xcodebuild archive failed (exit ${ARCHIVE_STATUS})." >&2
    echo "       Likely causes: wrong Team ID, profile name mismatch, or" >&2
    echo "       the bundle id is not registered in App Store Connect." >&2
    echo "       See ios/RELEASE.md § 'Resetting a broken signing setup'." >&2
    exit 2
fi

# -------------------------------------------------------------------------
# 2. Export .ipa.
# -------------------------------------------------------------------------
cat > "${EXPORT_OPTIONS}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>${EXPORT_METHOD}</string>
    <key>teamID</key>
    <string>${DEVELOPMENT_TEAM}</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>stripSwiftSymbols</key>
    <true/>
    <key>uploadBitcode</key>
    <false/>
    <key>uploadSymbols</key>
    <true/>
    <key>provisioningProfiles</key>
    <dict>
        <key>com.smithers.ios</key>
        <string>${PROVISIONING_PROFILE_SPECIFIER}</string>
    </dict>
</dict>
</plist>
EOF

echo "→ Exporting .ipa..."
set +e
xcodebuild \
    -exportArchive \
    -archivePath "${ARCHIVE_PATH}" \
    -exportOptionsPlist "${EXPORT_OPTIONS}" \
    -exportPath "${EXPORT_PATH}"
EXPORT_STATUS=$?
set -e
if [ ${EXPORT_STATUS} -ne 0 ]; then
    echo "error: xcodebuild -exportArchive failed (exit ${EXPORT_STATUS})." >&2
    exit 3
fi

IPA_PATH="$(ls -1 "${EXPORT_PATH}"/*.ipa 2>/dev/null | head -1 || true)"
if [ -z "${IPA_PATH}" ] || [ ! -f "${IPA_PATH}" ]; then
    echo "error: export succeeded but no .ipa found under ${EXPORT_PATH}." >&2
    exit 3
fi
echo "  → ${IPA_PATH}"

# -------------------------------------------------------------------------
# 3. Upload to TestFlight using App Store Connect API.
# -------------------------------------------------------------------------
if [ -n "${SKIP_UPLOAD:-}" ]; then
    echo "→ SKIP_UPLOAD set; stopping before TestFlight upload."
    exit 0
fi

# altool looks up the p8 key on disk under ~/.appstoreconnect/private_keys/
# (or one of a few other documented paths). Materialize the secret there.
KEY_DIR="${HOME}/.appstoreconnect/private_keys"
mkdir -p "${KEY_DIR}"
KEY_FILE="${KEY_DIR}/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
# Write with restrictive perms — this is credential material.
umask 077
printf '%s' "${APP_STORE_CONNECT_API_KEY_P8}" > "${KEY_FILE}"
umask 022

echo "→ Uploading to TestFlight..."
set +e
xcrun altool --upload-app \
    --type ios \
    --file "${IPA_PATH}" \
    --apiKey "${APP_STORE_CONNECT_API_KEY_ID}" \
    --apiIssuer "${APP_STORE_CONNECT_ISSUER_ID}"
UPLOAD_STATUS=$?
set -e

# Always shred the key material even on failure. The directory itself
# can stick around — altool caches against it.
rm -f "${KEY_FILE}"

if [ ${UPLOAD_STATUS} -ne 0 ]; then
    echo "error: TestFlight upload failed (exit ${UPLOAD_STATUS})." >&2
    echo "       Check that the API key has the 'App Manager' role and" >&2
    echo "       that the bundle id is registered in App Store Connect." >&2
    exit 4
fi

echo "✓ Ticket 0125 iOS release uploaded to TestFlight."
echo "  Processing usually takes 5–15 minutes; testers see it after that."
