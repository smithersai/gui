#!/usr/bin/env bash
# Build libghostty's XCFrameworks including iOS + iOS-simulator slices.
#
# Two separate xcframeworks are produced by a single `zig build`:
#
#   1. ghostty/macos/GhosttyKit.xcframework
#      The apprt (application-runtime) API — `ghostty_app_new` etc.
#      This is what the macOS Ghostty app embeds. For PoC 0092 we don't
#      use this one because its umbrella header does NOT expose the VT
#      C API symbols (VT symbols only compile in when `src/lib_vt.zig`
#      is the root module).
#
#   2. ghostty/zig-out/lib/ghostty-vt.xcframework
#      The libghostty-vt API — `ghostty_terminal_new`, `ghostty_formatter_*`.
#      This IS what the PoC links. iOS + iOS-simulator + macOS slices.
#
# Requirements:
#   - zig 0.15.2 (matches ghostty/build.zig.zon `minimum_zig_version`)
#   - Xcode 15+ with iOS 17+ SDK
#
# Typical wall time: ~90s on Apple Silicon.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$here/../../.." && pwd)"
ghostty_dir="$repo_root/ghostty"

if [[ ! -d "$ghostty_dir" ]]; then
  echo "error: ghostty submodule missing at $ghostty_dir" >&2
  echo "hint: run 'git submodule update --init --recursive ghostty' from the repo root" >&2
  exit 1
fi

if ! command -v zig >/dev/null 2>&1; then
  echo "error: zig not found in PATH" >&2
  echo "hint: install via zvm: zvm install 0.15.2 && zvm use 0.15.2" >&2
  exit 1
fi

zig_version="$(zig version)"
required_min="$(awk -F'"' '/minimum_zig_version/ { print $2 }' "$ghostty_dir/build.zig.zon")"
echo "zig version:     $zig_version"
echo "ghostty minimum: $required_min"

cd "$ghostty_dir"
exec zig build \
  -Demit-xcframework=true \
  -Dxcframework-target=universal \
  -Demit-macos-app=false \
  "$@"
