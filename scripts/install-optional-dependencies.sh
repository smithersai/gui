#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/install-optional-dependencies.sh [--runtime] [--build-tools] [--all] [--dry-run]

Installs optional SmithersGUI dependencies with Homebrew.

Options:
  --runtime      Install runtime extras: neovim. This is the default.
  --build-tools  Install Homebrew-managed build extras: xcodegen.
  --all          Install runtime and build extras.
  --dry-run      Print the brew command without running it.
  -h, --help     Show this help.

Notes:
  Agent CLIs such as claude, codex, gemini, kimi, amp, and forge are not
  installed by this script because each has separate auth and account setup.
  Rust and Zig are build dependencies; install Rust from https://rustup.rs and
  Zig 0.15.2 with zvm as described in README.md.
USAGE
}

install_runtime=0
install_build=0
dry_run=0
selection_seen=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      install_runtime=1
      selection_seen=1
      ;;
    --build-tools)
      install_build=1
      selection_seen=1
      ;;
    --all)
      install_runtime=1
      install_build=1
      selection_seen=1
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

if [[ "$selection_seen" -eq 0 ]]; then
  install_runtime=1
fi

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew is required for this helper: https://brew.sh" >&2
  exit 69
fi

packages=()
if [[ "$install_runtime" -eq 1 ]]; then
  packages+=(neovim)
fi
if [[ "$install_build" -eq 1 ]]; then
  packages+=(xcodegen)
fi

if [[ "${#packages[@]}" -eq 0 ]]; then
  echo "Nothing selected. Use --runtime, --build-tools, or --all." >&2
  exit 64
fi

missing=()
for package in "${packages[@]}"; do
  if ! brew list --formula "$package" >/dev/null 2>&1; then
    missing+=("$package")
  fi
done

if [[ "${#missing[@]}" -eq 0 ]]; then
  echo "All selected optional dependencies are already installed."
else
  if [[ "$dry_run" -eq 1 ]]; then
    printf 'brew install'
    printf ' %q' "${missing[@]}"
    printf '\n'
  else
    brew install "${missing[@]}"
  fi
fi

if [[ "$install_build" -eq 1 ]]; then
  if ! command -v rustup >/dev/null 2>&1 && ! command -v cargo >/dev/null 2>&1; then
    echo "Rust is still needed for full builds. Install it from https://rustup.rs."
  fi
  if ! command -v zvm >/dev/null 2>&1; then
    echo "Zig 0.15.2 is still needed for full builds. Install zvm, then run: zvm install 0.15.2 && zvm use 0.15.2"
  elif [[ -f .zigversion ]]; then
    zig_version="$(tr -d '[:space:]' < .zigversion)"
    if [[ -n "$zig_version" ]]; then
      if [[ "$dry_run" -eq 1 ]]; then
        echo "zvm install $zig_version && zvm use $zig_version"
      else
        zvm install "$zig_version"
        zvm use "$zig_version"
      fi
    fi
  fi
fi
