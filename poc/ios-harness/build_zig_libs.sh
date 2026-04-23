#!/usr/bin/env bash
# Build both Zig PoC libraries for all Xcode-driven slices.
#
# Outputs:
#   poc/ios-harness/.libs/iphonesimulator/libffi_poc.a      (aarch64-ios-simulator)
#   poc/ios-harness/.libs/iphonesimulator/libsqlite_poc.a
#   poc/ios-harness/.libs/iphoneos/libffi_poc.a             (aarch64-ios)
#   poc/ios-harness/.libs/iphoneos/libsqlite_poc.a
#   poc/ios-harness/.libs/macosx/libffi_poc.a               (native host)
#   poc/ios-harness/.libs/macosx/libsqlite_poc.a
#
# Invoked by an Xcode Run Script build phase (so it runs automatically on
# `xcodebuild test`) and also usable directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POC_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FFI_DIR="${POC_ROOT}/zig-swift-ffi"
SQL_DIR="${POC_ROOT}/zig-sqlite-ios"
OUT_DIR="${SCRIPT_DIR}/.libs"

mkdir -p "${OUT_DIR}/iphonesimulator" "${OUT_DIR}/iphoneos" "${OUT_DIR}/macosx"

build_one() {
    local zig_dir="$1"
    local zig_target="$2"
    local sdk_dir="$3"
    local artifact="$4"

    (
        cd "${zig_dir}"
        rm -rf zig-out
        zig build -Dtarget="${zig_target}" -Doptimize=ReleaseSmall
        cp "zig-out/lib/${artifact}" "${OUT_DIR}/${sdk_dir}/${artifact}"
    )
}

build_host_ffi() {
    (
        cd "${FFI_DIR}"
        rm -rf zig-out
        zig build -Doptimize=ReleaseSmall
        cp "zig-out/lib/libffi_poc.a" "${OUT_DIR}/macosx/libffi_poc.a"
    )
}

build_host_sql() {
    (
        cd "${SQL_DIR}"
        rm -rf zig-out
        zig build -Doptimize=ReleaseSmall
        cp "zig-out/lib/libsqlite_poc.a" "${OUT_DIR}/macosx/libsqlite_poc.a"
    )
}

build_one "${FFI_DIR}" "aarch64-ios-simulator" "iphonesimulator" "libffi_poc.a"
build_one "${FFI_DIR}" "aarch64-ios"           "iphoneos"        "libffi_poc.a"
build_host_ffi
build_one "${SQL_DIR}" "aarch64-ios-simulator" "iphonesimulator" "libsqlite_poc.a"
build_one "${SQL_DIR}" "aarch64-ios"           "iphoneos"        "libsqlite_poc.a"
build_host_sql

echo "Zig PoC libs built into ${OUT_DIR}"
