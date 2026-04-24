#!/usr/bin/env bash
# macos/scripts/run-e2e.sh — end-to-end driver for the macOS E2E XCUITest
# bundle.
#
# Ticket: macos-e2e-harness. Mirrors `ios/scripts/run-e2e.sh`. Steps:
#   1. Start the plue stack (`make docker-up` in the plue checkout).
#   2. Wait for Postgres + the api to accept traffic on localhost:4000.
#   3. Seed the E2E user / token / workspace by REUSING
#      `ios/scripts/seed-e2e-data.sh` verbatim (do NOT fork).
#   4. Regenerate `SmithersGUI.xcodeproj` via XcodeGen.
#   5. Run `xcodebuild test` for the `SmithersMacOSE2ETests` scheme
#      against the macOS destination, threading the E2E env vars.
#   6. Tear down (conditional on E2E_KEEP_STACK).
#
# Exit codes:
#   0  — all tests passed.
#   1  — test failures.
#   2  — environmental failure (docker, postgres, xcodebuild setup).
#
# Env knobs:
#   PLUE_CHECKOUT       path to the plue repo (default: user's worktree
#                       at /Users/williamcory/plue/.claude/worktrees/
#                       iort-0149-migration-numbers, with a fallback to
#                       ../plue for CI).
#   PLUE_BASE_URL       override base URL (default: http://localhost:4000)
#   E2E_KEEP_STACK      if "1", do NOT tear down on exit.
#   E2E_SCHEME          default "SmithersMacOSE2ETests"

set -euo pipefail

DEFAULT_PLUE_WORKTREE="/Users/williamcory/plue/.claude/worktrees/iort-0149-migration-numbers"
if [[ -z "${PLUE_CHECKOUT:-}" ]]; then
    if [[ -d "$DEFAULT_PLUE_WORKTREE" ]]; then
        PLUE_CHECKOUT="$DEFAULT_PLUE_WORKTREE"
    else
        PLUE_CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/../plue"
    fi
fi

PLUE_BASE_URL="${PLUE_BASE_URL:-http://localhost:4000}"
E2E_KEEP_STACK="${E2E_KEEP_STACK:-0}"
E2E_SCHEME="${E2E_SCHEME:-SmithersMacOSE2ETests}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

log() { echo "[macos-e2e] $*" >&2; }

die() {
    echo "[macos-e2e] FAIL: $*" >&2
    exit 2
}

cleanup() {
    local rc=$?
    if [[ "$E2E_KEEP_STACK" != "1" ]]; then
        log "tearing down plue stack (E2E_KEEP_STACK=0)"
        (cd "$PLUE_CHECKOUT" && docker compose down -v >/dev/null 2>&1 || true)
    else
        log "leaving plue stack up (E2E_KEEP_STACK=1)"
    fi
    if [[ $rc -ne 0 ]]; then
        log "xcresult bundles (if any): $(ls -td "$REPO_ROOT"/build/macos-e2e-results-*.xcresult 2>/dev/null | head -1)"
    fi
    exit "$rc"
}
trap cleanup EXIT

# Ensure psql from libpq is on PATH for the seed script.
if ! command -v psql >/dev/null 2>&1; then
    if [[ -x /opt/homebrew/opt/libpq/bin/psql ]]; then
        export PATH="/opt/homebrew/opt/libpq/bin:$PATH"
    elif [[ -x /usr/local/opt/libpq/bin/psql ]]; then
        export PATH="/usr/local/opt/libpq/bin:$PATH"
    else
        die "psql not on PATH and libpq not installed — run 'brew install libpq'"
    fi
fi

# ---------------------------------------------------------------------------
# 1. Plue stack
# ---------------------------------------------------------------------------
if [[ ! -d "$PLUE_CHECKOUT" ]]; then
    die "plue checkout not found at $PLUE_CHECKOUT (override with PLUE_CHECKOUT=...)"
fi

# Check if the stack is already up to avoid redundant `make docker-up`.
if curl -sf -o /dev/null -w '%{http_code}' "$PLUE_BASE_URL/api/health" 2>/dev/null | grep -qE '^(200|404|401)$'; then
    log "plue stack already reachable at $PLUE_BASE_URL — skipping docker-up"
else
    log "starting plue stack at $PLUE_CHECKOUT"
    if ! (cd "$PLUE_CHECKOUT" && make docker-up); then
        log "make docker-up failed — attempting bun install recovery…"
        if [[ -d "$PLUE_CHECKOUT/apps/workflow-runtime" ]]; then
            (cd "$PLUE_CHECKOUT/apps/workflow-runtime" && bun install) || true
        fi
        (cd "$PLUE_CHECKOUT" && bun install) || true
        if ! (cd "$PLUE_CHECKOUT" && make docker-up); then
            die "make docker-up still failing after bun install; inspect $PLUE_CHECKOUT"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2. Wait for services
# ---------------------------------------------------------------------------
log "waiting for plue api on $PLUE_BASE_URL"
deadline=$((SECONDS + 120))
until curl -sf -o /dev/null -w '%{http_code}' "$PLUE_BASE_URL/api/health" 2>/dev/null | grep -qE '^(200|404|401)$'; do
    if (( SECONDS >= deadline )); then
        die "plue api not reachable at $PLUE_BASE_URL after 120s"
    fi
    sleep 2
done
log "plue api reachable"

# ---------------------------------------------------------------------------
# 3. Seed test data — reuse the iOS seed script verbatim.
# ---------------------------------------------------------------------------
SEED_SCRIPT="$REPO_ROOT/ios/scripts/seed-e2e-data.sh"
if [[ ! -x "$SEED_SCRIPT" ]]; then
    die "seed script not executable: $SEED_SCRIPT"
fi

log "seeding E2E user/token/workspace via $SEED_SCRIPT"
SEED_OUT="$("$SEED_SCRIPT")"
while IFS='=' read -r k v; do
    [[ -z "$k" ]] && continue
    export "$k=$v"
done <<< "$SEED_OUT"
log "seeded token: ${SMITHERS_E2E_BEARER:0:16}… (workspace_id=$PLUE_E2E_WORKSPACE_ID)"

# ---------------------------------------------------------------------------
# 4. Regenerate project
# ---------------------------------------------------------------------------
if ! command -v xcodegen >/dev/null 2>&1; then
    die "xcodegen not installed — run 'brew install xcodegen'"
fi
log "regenerating SmithersGUI.xcodeproj"
(cd "$REPO_ROOT" && xcodegen >/dev/null)

# ---------------------------------------------------------------------------
# 5. xcodebuild test
# ---------------------------------------------------------------------------
mkdir -p "$REPO_ROOT/build"
XCRESULT="$REPO_ROOT/build/macos-e2e-results-$(date +%Y%m%d-%H%M%S).xcresult"

log "running xcodebuild test → $XCRESULT"

# Scheme env macros (see project.yml) resolve against the invoking
# process environment at test time. Export everything the tests need.
export SMITHERS_E2E_BEARER
export PLUE_BASE_URL
export PLUE_E2E_MODE=1
export PLUE_REMOTE_SANDBOX_ENABLED=1
export PLUE_E2E_SEEDED=1
export PLUE_E2E_SEEDED_WORKSPACE_TITLE="${PLUE_E2E_SEEDED_WORKSPACE_TITLE:-e2e-workspace}"
export PLUE_E2E_WORKSPACE_ID
export SMITHERS_E2E_REFRESH="${SMITHERS_E2E_REFRESH:-}"

# macOS builds do NOT need the iOS env scrub (SDKROOT / LIBRARY_PATH /
# RUSTFLAGS) — those unset-s are iOS-Simulator-specific. We run with
# the user's shell env intact so ghostty + libsmithers link paths
# resolve correctly.
set +e
xcodebuild \
    -project "$REPO_ROOT/SmithersGUI.xcodeproj" \
    -scheme "$E2E_SCHEME" \
    -destination "platform=macOS" \
    -resultBundlePath "$XCRESULT" \
    test 2>&1 | tee "$REPO_ROOT/build/macos-e2e-xcodebuild.log"
rc=${PIPESTATUS[0]}
set -e

if (( rc != 0 )); then
    log "xcodebuild test FAILED (rc=$rc). xcresult bundle: $XCRESULT"
    exit 1
fi

log "all macOS E2E tests PASSED"
log "xcresult: $XCRESULT"
exit 0
