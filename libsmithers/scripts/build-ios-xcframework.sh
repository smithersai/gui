#!/usr/bin/env bash
# Build libsmithers's iOS XCFramework (ticket 0172).
#
# Produces:
#   libsmithers/zig-out/lib/libsmithers-ios.xcframework/
#     ios-arm64/             libsmithers.a + Headers/
#     ios-arm64-simulator/   libsmithers.a + Headers/
#
# Two slices: device (`arm64-apple-ios`) and Apple-Silicon simulator
# (`arm64-apple-ios-simulator`). The project is Apple-Silicon-only per
# README.md, so `x86_64-apple-ios-simulator` is intentionally skipped.
#
# Requirements:
#   - zig 0.15.2 (matches libsmithers/build.zig `required_zig`)
#   - Xcode 15+ with iOS 17+ SDK
#
# Typical wall time: ~30s on Apple Silicon.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
libsmithers_dir="$(cd "$here/.." && pwd)"

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig not found in PATH" >&2
  echo "hint: install via zvm: zvm install 0.15.2 && zvm use 0.15.2" >&2
  exit 1
fi

if ! command -v xcrun >/dev/null 2>&1; then
  echo "error: xcrun not found — Xcode command line tools required" >&2
  exit 1
fi

cd "$libsmithers_dir"

# iOS deployment target. Matches IPHONEOS_DEPLOYMENT_TARGET in project.yml.
ios_min="17.0"

# SDK paths feed into Zig's libc detection (so `linkSystemLibrary("sqlite3")`
# resolves against the iOS SDK's libsqlite3.tbd at archive time).
ios_sdk="$(xcrun --sdk iphoneos --show-sdk-path)"
sim_sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"

build_slice() {
  local triple="$1" prefix="$2" sdk="$3"
  echo "→ libsmithers iOS slice: $triple"
  rm -rf "$prefix"
  # SDKROOT teaches zig + libsmithers/build.zig where to find libsqlite3.tbd.
  SDKROOT="$sdk" zig build \
    -Dtarget="$triple" \
    -Doptimize=ReleaseFast \
    --prefix "$prefix"
}

build_slice "aarch64-ios.${ios_min}" "zig-out-ios-device" "$ios_sdk"
build_slice "aarch64-ios.${ios_min}-simulator" "zig-out-ios-sim" "$sim_sdk"

device_lib="zig-out-ios-device/lib/libsmithers.a"
sim_lib="zig-out-ios-sim/lib/libsmithers.a"
for lib in "$device_lib" "$sim_lib"; do
  if [ ! -f "$lib" ]; then
    echo "error: expected static archive missing: $lib" >&2
    exit 2
  fi
done

out="zig-out/lib/libsmithers-ios.xcframework"
rm -rf "$out"
mkdir -p "$(dirname "$out")"

# Bundle ONLY the static archives. Headers stay in the top-level
# CSmithersKit/ shim and are surfaced to the iOS target via SWIFT_INCLUDE_PATHS
# (project.yml). Embedding a Headers/ slice here would collide with
# ghostty-vt.xcframework's Headers/module.modulemap during ProcessXCFramework
# (Xcode flattens both into Build/Products/<config>/include/).
xcodebuild -create-xcframework \
  -library "$device_lib" \
  -library "$sim_lib" \
  -output "$out"

echo "✓ libsmithers iOS xcframework: $out"
