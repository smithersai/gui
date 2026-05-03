#!/usr/bin/env bash
# ios/scripts/build-and-upload-testflight.sh — ticket 0125.

set -euo pipefail

if [ -z "${SMITHERS_SKIP_ENV_SCRUB:-}" ]; then
    exec env -u SDKROOT -u LIBRARY_PATH -u RUSTFLAGS SMITHERS_SKIP_ENV_SCRUB=1 "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${REPO_ROOT}"

require() {
    local name="$1"
    if [ -z "${!name:-}" ]; then
        echo "error: required input \$$name is not set." >&2
        echo "       See ios/RELEASE.md for how to plumb it in." >&2
        exit 1
    fi
}

UPLOAD_ENABLED=1
if [ -n "${SKIP_UPLOAD:-}" ]; then
    UPLOAD_ENABLED=0
fi

require DEVELOPMENT_TEAM
require PROVISIONING_PROFILE_SPECIFIER
require SHARE_EXTENSION_PROVISIONING_PROFILE_SPECIFIER

if [ "${UPLOAD_ENABLED}" -eq 1 ]; then
    require APP_STORE_CONNECT_API_KEY_ID
    require APP_STORE_CONNECT_ISSUER_ID
    require APP_STORE_CONNECT_API_KEY_P8
fi

GHOSTTY_VT_XCFRAMEWORK="ghostty/zig-out/lib/ghostty-vt.xcframework"
if [ ! -d "${GHOSTTY_VT_XCFRAMEWORK}" ]; then
    echo "error: ${GHOSTTY_VT_XCFRAMEWORK} is missing." >&2
    echo "       Run 'poc/libghostty-ios/scripts/build-xcframework.sh'" >&2
    echo "       (requires zig $(cat .zigversion 2>/dev/null || echo '0.15.2'))" >&2
    echo "       or restore it from the CI cache." >&2
    exit 1
fi

LIBSMITHERS_IOS_XCFRAMEWORK="libsmithers/zig-out/lib/libsmithers-ios.xcframework"
if [ ! -d "${LIBSMITHERS_IOS_XCFRAMEWORK}" ]; then
    echo "error: ${LIBSMITHERS_IOS_XCFRAMEWORK} is missing." >&2
    echo "       Run 'libsmithers/scripts/build-ios-xcframework.sh'" >&2
    echo "       (requires zig $(cat .zigversion 2>/dev/null || echo '0.15.2'))" >&2
    echo "       or restore it from the CI cache." >&2
    exit 1
fi

MARKETING_VERSION="${MARKETING_VERSION:-$(awk '/MARKETING_VERSION:/ {gsub(/["'\''']/, "", $2); print $2; exit}' project.yml)}"
CURRENT_PROJECT_VERSION="${CURRENT_PROJECT_VERSION:-${GITHUB_RUN_NUMBER:-1}}"
EXPORT_METHOD="${EXPORT_METHOD:-app-store}"

BUILD_DIR="build/ios-archive"
ARCHIVE_PATH="${BUILD_DIR}/SmithersiOS.xcarchive"
EXPORT_PATH="${BUILD_DIR}"
EXPORT_OPTIONS="${BUILD_DIR}/ExportOptions.plist"

mkdir -p "${BUILD_DIR}"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "error: xcodegen is not installed. 'brew install xcodegen'." >&2
    exit 1
fi
if ! command -v security >/dev/null 2>&1; then
    echo "error: macOS 'security' CLI is unavailable; cannot validate provisioning profiles." >&2
    exit 1
fi

APP_PROFILE_PATH="${HOME}/Library/MobileDevice/Provisioning Profiles/smithers-ios-appstore.mobileprovision"
SHARE_PROFILE_PATH="${HOME}/Library/MobileDevice/Provisioning Profiles/smithers-ios-shareext-appstore.mobileprovision"
mkdir -p "libsmithers/zig-out/bin/smithers-session-daemon"
mkdir -p "libsmithers/zig-out/bin/smithers-session-connect"

validate_profile() {
    local profile_path="$1"
    local expected_bundle_id="$2"
    local profile_label="$3"

    if [ ! -f "${profile_path}" ]; then
        echo "error: ${profile_label} provisioning profile missing at ${profile_path}" >&2
        echo "       Install provisioning profiles before archive/export." >&2
        exit 1
    fi

    local decoded expected full_bundle app_id_prefix
    decoded="$(security cms -D -i "${profile_path}" 2>/dev/null)" || {
        echo "error: failed to decode ${profile_label} provisioning profile: ${profile_path}" >&2
        exit 1
    }

    app_id_prefix="$(printf '%s' "${decoded}" | /usr/libexec/PlistBuddy -c 'Print :ApplicationIdentifierPrefix:0' /dev/stdin 2>/dev/null || true)"
    full_bundle="$(printf '%s' "${decoded}" | /usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' /dev/stdin 2>/dev/null || true)"

    if [ -z "${app_id_prefix}" ] || [ -z "${full_bundle}" ]; then
        echo "error: could not read application identifier fields from ${profile_label} provisioning profile." >&2
        exit 1
    fi

    expected="${app_id_prefix}.${expected_bundle_id}"
    if [ "${full_bundle}" != "${expected}" ]; then
        echo "error: ${profile_label} provisioning profile bundle id mismatch." >&2
        echo "       expected ${expected} but profile contains ${full_bundle}" >&2
        exit 1
    fi
}

validate_profile "${APP_PROFILE_PATH}" "com.smithers.ios" "App"
validate_profile "${SHARE_PROFILE_PATH}" "com.smithers.ios.ShareExtension" "Share extension"

echo "→ Ticket 0125 iOS release build"
echo "  MARKETING_VERSION       = ${MARKETING_VERSION}"
echo "  CURRENT_PROJECT_VERSION = ${CURRENT_PROJECT_VERSION}"
echo "  DEVELOPMENT_TEAM        = ${DEVELOPMENT_TEAM}"
echo "  PROVISIONING_PROFILE    = ${PROVISIONING_PROFILE_SPECIFIER}"
echo "  SHARE_EXT_PROFILE       = ${SHARE_EXTENSION_PROVISIONING_PROFILE_SPECIFIER}"
echo "  EXPORT_METHOD           = ${EXPORT_METHOD}"
if [ "${UPLOAD_ENABLED}" -eq 0 ]; then
    echo "  SKIP_UPLOAD             = 1 (archive/export only)"
fi

xcodegen generate

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
    SMITHERS_BASE_URL="${SMITHERS_BASE_URL:-${PLUE_BASE_URL:-https://app.smithers.sh}}" \
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
        <key>com.smithers.ios.ShareExtension</key>
        <string>${SHARE_EXTENSION_PROVISIONING_PROFILE_SPECIFIER}</string>
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

if [ "${UPLOAD_ENABLED}" -eq 0 ]; then
    echo "→ SKIP_UPLOAD set; stopping before TestFlight upload."
    exit 0
fi

KEY_DIR="${HOME}/.appstoreconnect/private_keys"
mkdir -p "${KEY_DIR}"
KEY_FILE="${KEY_DIR}/AuthKey_${APP_STORE_CONNECT_API_KEY_ID}.p8"
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
rm -f "${KEY_FILE}"

if [ ${UPLOAD_STATUS} -ne 0 ]; then
    echo "error: TestFlight upload failed (exit ${UPLOAD_STATUS})." >&2
    echo "       Check that the API key has the 'App Manager' role and" >&2
    echo "       that the bundle id is registered in App Store Connect." >&2
    exit 4
fi

echo "✓ Ticket 0125 iOS release uploaded to TestFlight."
