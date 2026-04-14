#!/bin/bash
set -e

echo "Building codex-ffi (Rust)..."
cd codex/codex-rs
cargo build -p codex-ffi --release
cd ../..

echo "Building SmithersGUI (Swift)..."
swift build

echo "Done! Run with: .build/debug/SmithersGUI"
