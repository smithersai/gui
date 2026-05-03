#!/usr/bin/env bash
# macos/scripts/run-e2e.sh — end-to-end driver for the macOS E2E XCUITest
# bundle.
#
# Ticket: macos-e2e-harness. Mirrors `ios/scripts/run-e2e.sh`. Steps:
#   1. Start the Smithers stack (`make docker-up` in the backend checkout).
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
#   SMITHERS_CHECKOUT   path to the Smithers backend repo (default: user's worktree
#                       at /Users/williamcory/plue/.claude/worktrees/
#                       iort-0149-migration-numbers, with a fallback to
#                       ../plue for CI).
#   SMITHERS_BASE_URL   override base URL (default: http://localhost:4000)
#   E2E_KEEP_STACK      if "1", do NOT tear down on exit.
#   E2E_SCHEME          default "SmithersMacOSE2ETests"

set -euo pipefail

DEFAULT_PLUE_WORKTREE="/Users/williamcory/plue/.claude/worktrees/iort-0149-migration-numbers"
if [[ -z "${SMITHERS_CHECKOUT:-}" && -z "${PLUE_CHECKOUT:-}" ]]; then
    if [[ -d "$DEFAULT_PLUE_WORKTREE" ]]; then
        SMITHERS_CHECKOUT="$DEFAULT_PLUE_WORKTREE"
    else
        SMITHERS_CHECKOUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/../plue"
    fi
fi
SMITHERS_CHECKOUT="${SMITHERS_CHECKOUT:-${PLUE_CHECKOUT:-}}"

SMITHERS_BASE_URL="${SMITHERS_BASE_URL:-${PLUE_BASE_URL:-http://localhost:4000}}"
E2E_KEEP_STACK="${E2E_KEEP_STACK:-0}"
E2E_SCHEME="${E2E_SCHEME:-SmithersMacOSE2ETests}"
E2E_ONLY_TESTING="${E2E_ONLY_TESTING:-SmithersMacOSE2ETests/SmithersMacOSE2EHappyPathTests}"

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
        log "tearing down Smithers stack (E2E_KEEP_STACK=0)"
        (cd "$SMITHERS_CHECKOUT" && docker compose down -v >/dev/null 2>&1 || true)
    else
        log "leaving Smithers stack up (E2E_KEEP_STACK=1)"
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
# 1. Smithers stack
# ---------------------------------------------------------------------------
if [[ ! -d "$SMITHERS_CHECKOUT" ]]; then
    die "Smithers backend checkout not found at $SMITHERS_CHECKOUT (override with SMITHERS_CHECKOUT=...)"
fi

# Check if the stack is already up to avoid redundant `make docker-up`.
if curl -sf -o /dev/null -w '%{http_code}' "$SMITHERS_BASE_URL/api/health" 2>/dev/null | grep -qE '^(200|404|401)$'; then
    log "Smithers stack already reachable at $SMITHERS_BASE_URL — skipping docker-up"
else
    log "starting Smithers stack at $SMITHERS_CHECKOUT"
    if ! (cd "$SMITHERS_CHECKOUT" && make docker-up); then
        log "make docker-up failed — attempting bun install recovery…"
        if [[ -d "$SMITHERS_CHECKOUT/apps/workflow-runtime" ]]; then
            (cd "$SMITHERS_CHECKOUT/apps/workflow-runtime" && bun install) || true
        fi
        (cd "$SMITHERS_CHECKOUT" && bun install) || true
        if ! (cd "$SMITHERS_CHECKOUT" && make docker-up); then
            die "make docker-up still failing after bun install; inspect $SMITHERS_CHECKOUT"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# 2. Wait for services
# ---------------------------------------------------------------------------
log "waiting for Smithers API on $SMITHERS_BASE_URL"
deadline=$((SECONDS + 120))
until curl -sf -o /dev/null -w '%{http_code}' "$SMITHERS_BASE_URL/api/health" 2>/dev/null | grep -qE '^(200|404|401)$'; do
    if (( SECONDS >= deadline )); then
        die "Smithers API not reachable at $SMITHERS_BASE_URL after 120s"
    fi
    sleep 2
done
log "Smithers API reachable"

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
log "only-testing: $E2E_ONLY_TESTING"

# Scheme env macros (see project.yml) resolve against the invoking
# process environment at test time. Export everything the tests need.
export SMITHERS_E2E_BEARER
export SMITHERS_BASE_URL
export PLUE_BASE_URL="$SMITHERS_BASE_URL"
export SMITHERS_E2E_MODE=1
export SMITHERS_REMOTE_SANDBOX_ENABLED=1
export PLUE_REMOTE_SANDBOX_ENABLED="$SMITHERS_REMOTE_SANDBOX_ENABLED"
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
    -only-testing "$E2E_ONLY_TESTING" \
    test 2>&1 | tee "$REPO_ROOT/build/macos-e2e-xcodebuild.log"
rc=${PIPESTATUS[0]}
set -e

if (( rc != 0 )); then
    log "xcodebuild test FAILED (rc=$rc). xcresult bundle: $XCRESULT"
    exit 1
fi

log "all macOS E2E tests PASSED"
log "xcresult: $XCRESULT"
log "xcodebuild log: $REPO_ROOT/build/macos-e2e-xcodebuild.log"
exit 0
