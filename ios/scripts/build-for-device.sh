#!/usr/bin/env bash
# Build SmithersiOS with a device-reachable Plue backend URL baked into
# Info.plist. Defaults to LAN testing; source build/preview-tunnel/*.env first
# to use an ngrok preview URL instead.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUI_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SOURCE_PLIST="$GUI_ROOT/ios/Sources/SmithersiOS/Info.plist"
STATE_DIR="${IOS_DEVICE_BUILD_STATE_DIR:-$GUI_ROOT/build/ios-device}"
GENERATED_PLIST="$STATE_DIR/Info.device.plist"
DERIVED_DATA_PATH="${IOS_DERIVED_DATA_PATH:-$STATE_DIR/DerivedData}"
SCHEME="${IOS_SCHEME:-SmithersiOS}"
CONFIGURATION="${IOS_CONFIGURATION:-Debug}"
if [[ -n "${IOS_DESTINATION:-}" ]]; then
    DESTINATION="$IOS_DESTINATION"
elif [[ -n "${DEVICE_ID:-}" ]]; then
    DESTINATION="id=$DEVICE_ID"
else
    DESTINATION="generic/platform=iOS"
fi
LAN_INTERFACE="${PLUE_LAN_INTERFACE:-en0}"
PLUE_PORT="${PLUE_PORT:-4000}"
INSTALL_ON_DEVICE="${INSTALL_ON_DEVICE:-}"

log() { echo "[build-for-device] $*" >&2; }

die() {
    echo "[build-for-device] FAIL: $*" >&2
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

detect_lan_ip() {
    local ip=""
    ip="$(ipconfig getifaddr "$LAN_INTERFACE" 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
        ip="$(ipconfig getifaddr en1 2>/dev/null || true)"
    fi
    [[ -n "$ip" ]] || die "could not detect LAN IP with ipconfig getifaddr $LAN_INTERFACE"
    printf '%s\n' "$ip"
}

trim_base_url() {
    local value="$1"
    while [[ "$value" == */ ]]; do
        value="${value%/}"
    done
    if [[ "$value" == */api ]]; then
        value="${value%/api}"
    fi
    printf '%s\n' "$value"
}

url_part() {
    local mode="$1"
    local url="$2"
    /usr/bin/python3 - "$mode" "$url" <<'PY'
import sys
from urllib.parse import urlparse

mode, raw = sys.argv[1], sys.argv[2]
parsed = urlparse(raw)
if not parsed.scheme or not parsed.hostname:
    sys.exit(1)
if mode == "scheme":
    print(parsed.scheme.lower())
elif mode == "host":
    print(parsed.hostname)
else:
    sys.exit(1)
PY
}

select_base_url() {
    local raw="${PLUE_DEVICE_BASE_URL:-}"
    if [[ -z "$raw" && -n "${PLUE_PREVIEW_URL:-}" ]]; then
        raw="$PLUE_PREVIEW_URL"
    fi
    if [[ -z "$raw" && -n "${PLUE_BASE_URL:-}" ]]; then
        raw="$PLUE_BASE_URL"
    fi
    if [[ -z "$raw" ]]; then
        local lan_ip
        lan_ip="${PLUE_LAN_IP:-$(detect_lan_ip)}"
        raw="http://${lan_ip}:${PLUE_PORT}"
    fi
    trim_base_url "$raw"
}

plist_ensure_dict() {
    local path="$1"
    /usr/libexec/PlistBuddy -c "Print $path" "$GENERATED_PLIST" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add $path dict" "$GENERATED_PLIST" >/dev/null
}

plist_set_string() {
    local path="$1"
    local value="$2"
    /usr/libexec/PlistBuddy -c "Set $path $value" "$GENERATED_PLIST" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add $path string $value" "$GENERATED_PLIST" >/dev/null
}

plist_set_bool() {
    local path="$1"
    local value="$2"
    /usr/libexec/PlistBuddy -c "Set $path $value" "$GENERATED_PLIST" >/dev/null 2>&1 \
        || /usr/libexec/PlistBuddy -c "Add $path bool $value" "$GENERATED_PLIST" >/dev/null
}

prepare_info_plist() {
    local base_url="$1"
    local scheme="$2"
    local host="$3"

    mkdir -p "$STATE_DIR"
    cp "$SOURCE_PLIST" "$GENERATED_PLIST"
    plist_set_string ":SmithersPlueBaseURL" "$base_url"
    plist_set_string ":SmithersPreviewURL" "${PLUE_PREVIEW_URL:-}"

    if [[ "$scheme" == "http" ]]; then
        plist_ensure_dict ":NSAppTransportSecurity"
        plist_ensure_dict ":NSAppTransportSecurity:NSExceptionDomains"
        plist_ensure_dict ":NSAppTransportSecurity:NSExceptionDomains:$host"
        plist_set_bool ":NSAppTransportSecurity:NSExceptionDomains:$host:NSExceptionAllowsInsecureHTTPLoads" true
        plist_set_bool ":NSAppTransportSecurity:NSExceptionDomains:$host:NSIncludesSubdomains" false
    fi

    plutil -lint "$GENERATED_PLIST" >/dev/null
}

detect_device_id() {
    xcrun devicectl list devices --json-output - 2>/dev/null \
        | /usr/bin/python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    sys.exit(0)

for device in payload.get("result", {}).get("devices", []):
    identifier = device.get("identifier") or device.get("udid")
    if identifier:
        print(identifier)
        sys.exit(0)
' 2>/dev/null || true
}

install_app_if_requested() {
    local app_path="$1"
    local requested="${INSTALL_ON_DEVICE}"

    if [[ -z "$requested" && -n "${DEVICE_ID:-}" ]]; then
        requested="1"
    fi
    [[ "$requested" == "1" ]] || return

    local device_id="${DEVICE_ID:-}"
    if [[ -z "$device_id" ]]; then
        device_id="$(detect_device_id)"
    fi
    [[ -n "$device_id" ]] || die "INSTALL_ON_DEVICE=1 needs DEVICE_ID or one connected iOS device"

    log "installing $app_path on device $device_id"
    xcrun devicectl device install app --device "$device_id" "$app_path"
}

main() {
    require_command xcodebuild
    require_command /usr/bin/python3
    require_command /usr/libexec/PlistBuddy
    require_command plutil
    require_command xcrun

    [[ -f "$SOURCE_PLIST" ]] || die "missing source Info.plist at $SOURCE_PLIST"

    local base_url scheme host
    base_url="$(select_base_url)"
    scheme="$(url_part scheme "$base_url")" || die "invalid PLUE base URL: $base_url"
    host="$(url_part host "$base_url")" || die "invalid PLUE base URL: $base_url"

    prepare_info_plist "$base_url" "$scheme" "$host"

    log "PLUE_BASE_URL=$base_url"
    log "generated Info.plist=$GENERATED_PLIST"
    if [[ "$scheme" == "http" ]]; then
        log "ATS exception domain=$host"
    else
        log "ATS exception domain=<none needed for https>"
    fi

    if [[ "${SKIP_XCODE_BUILD:-0}" == "1" ]]; then
        return
    fi

    local build_settings=(
        "INFOPLIST_FILE=$GENERATED_PLIST"
        "PLUE_BASE_URL=$base_url"
        "PLUE_PREVIEW_URL=${PLUE_PREVIEW_URL:-}"
        "CODE_SIGN_STYLE=${IOS_CODE_SIGN_STYLE:-Automatic}"
        "CODE_SIGNING_ALLOWED=YES"
        "CODE_SIGNING_REQUIRED=YES"
        "CODE_SIGN_IDENTITY=${IOS_CODE_SIGN_IDENTITY:-Apple Development}"
    )

    if [[ -n "${DEVELOPMENT_TEAM:-}" ]]; then
        build_settings+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
    fi
    if [[ -n "${PROVISIONING_PROFILE_SPECIFIER:-}" ]]; then
        build_settings+=("PROVISIONING_PROFILE_SPECIFIER=$PROVISIONING_PROFILE_SPECIFIER")
    fi

    local provisioning_args=()
    if [[ "${IOS_ALLOW_PROVISIONING_UPDATES:-1}" == "1" ]]; then
        provisioning_args+=("-allowProvisioningUpdates")
    fi

    log "building $SCHEME ($CONFIGURATION) for destination: $DESTINATION"
    xcodebuild \
        -project "$GUI_ROOT/SmithersGUI.xcodeproj" \
        -scheme "$SCHEME" \
        -configuration "$CONFIGURATION" \
        -destination "$DESTINATION" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        "${provisioning_args[@]}" \
        build \
        "${build_settings[@]}"

    local app_path
    app_path="$(find "$DERIVED_DATA_PATH/Build/Products" -type d -path "*/${CONFIGURATION}-iphoneos/*.app" | head -1)"
    [[ -n "$app_path" ]] || die "build completed but no iphoneos .app was found in $DERIVED_DATA_PATH"

    log "built app=$app_path"
    install_app_if_requested "$app_path"
}

main "$@"
