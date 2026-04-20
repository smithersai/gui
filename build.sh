#!/bin/bash
set -e

echo "Building codex-ffi (Rust)..."
cd codex-ffi
cargo build --release
cd ..

echo "Building SmithersGUI (Swift)..."
swift build

echo "Done! Run with: .build/debug/SmithersGUI"
