#!/usr/bin/env sh
set -eu

cd "$(dirname "$0")/.."
zig build -Dstub-libsmithers=true

if command -v xvfb-run >/dev/null 2>&1; then
  timeout 8s xvfb-run -a zig-out/bin/smithers-gtk --smoke --show-palette
else
  echo "xvfb-run not found; run this manually under a graphical session:"
  echo "  zig-out/bin/smithers-gtk --smoke --show-palette"
fi
