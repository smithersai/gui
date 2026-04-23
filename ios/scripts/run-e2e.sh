#!/usr/bin/env bash
# ios/scripts/run-e2e.sh — end-to-end driver for the iOS E2E XCUITest
# bundle.
#
# Ticket: ios-e2e-harness. Steps:
#   1. Start the plue stack (`make docker-up` in the plue checkout).
#   2. Wait for Postgres + the api to accept traffic on localhost:4000.
#   3. Seed the E2E user / token / workspace via `seed-e2e-data.sh`.
#   4. Regenerate `SmithersGUI.xcodeproj` via XcodeGen.
#   5. Boot the simulator + run `xcodebuild test` for the
#      `SmithersiOSE2ETests` scheme, threading the E2E env vars.
#   6. Tear down (conditional on E2E_KEEP_STACK).
#
# The script is idempotent: re-running will reuse the already-running
# postgres + api if they are healthy. Exit codes:
#   0  — all tests passed.
#   1  — test failures (see uploaded xcresult bundle for details).
#   2  — environmental failure (docker, postgres, xcodebuild setup).
#
# Env knobs:
#   PLUE_CHECKOUT       path to the plue repo (default: ../plue)
#   PLUE_BASE_URL       override base URL (default: http://localhost:4000)
#   E2E_KEEP_STACK      if "1", do NOT tear down on exit (leave postgres
#                       + api running so you can re-run tests cheaply).
#   E2E_SIMULATOR_NAME  default "iPhone 16"
#   E2E_SIMULATOR_OS    default "18.6"
#   E2E_SCHEME          default "SmithersiOSE2ETests"

set -euo pipefail

PLUE_CHECKOUT="${PLUE_CHECKOUT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/../plue}"
PLUE_BASE_URL="${PLUE_BASE_URL:-http://localhost:4000}"
E2E_KEEP_STACK="${E2E_KEEP_STACK:-0}"
E2E_SIMULATOR_NAME="${E2E_SIMULATOR_NAME:-iPhone 16}"
E2E_SIMULATOR_OS="${E2E_SIMULATOR_OS:-18.6}"
E2E_SCHEME="${E2E_SCHEME:-SmithersiOSE2ETests}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# User's shell has LIBRARY_PATH + SDKROOT + RUSTFLAGS from Rust tooling.
# Strip them — xcodebuild picks up wrong SDK paths otherwise. Also
# prepend Homebrew's keg-only libpq (psql) so the seed script can reach
# Postgres in a non-interactive shell where the user's `zshrc` didn't
# run (e.g. invoked from CI or a plain bash subprocess).
export_clean_env() {
    unset SDKROOT
    unset LIBRARY_PATH
    unset RUSTFLAGS
    unset DYLD_LIBRARY_PATH
    unset DYLD_FRAMEWORK_PATH
    export PATH="/opt/homebrew/opt/libpq/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"
}

log() { echo "[run-e2e] $*" >&2; }

die() {
    echo "[run-e2e] FAIL: $*" >&2
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
        log "xcresult bundles (if any): $(ls -td "$REPO_ROOT"/build/e2e-results-*.xcresult 2>/dev/null | head -1)"
    fi
    exit "$rc"
}
trap cleanup EXIT

export_clean_env

# ---------------------------------------------------------------------------
# 1. Plue stack
# ---------------------------------------------------------------------------
if [[ ! -d "$PLUE_CHECKOUT" ]]; then
    die "plue checkout not found at $PLUE_CHECKOUT (override with PLUE_CHECKOUT=...)"
fi

log "starting plue stack at $PLUE_CHECKOUT"
if ! (cd "$PLUE_CHECKOUT" && make docker-up); then
    log "make docker-up failed — likely the bun.lock drift issue."
    log "attempting bun install as the ticket suggests, then retrying…"
    if [[ -d "$PLUE_CHECKOUT/apps/workflow-runtime" ]]; then
        (cd "$PLUE_CHECKOUT/apps/workflow-runtime" && bun install) || true
    fi
    (cd "$PLUE_CHECKOUT" && bun install) || true
    if ! (cd "$PLUE_CHECKOUT" && make docker-up); then
        die "make docker-up still failing after bun install; inspect $PLUE_CHECKOUT"
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
# 3. Seed test data
# ---------------------------------------------------------------------------
log "seeding E2E user/token/workspace"
SEED_OUT="$("$SCRIPT_DIR/seed-e2e-data.sh")"
# Export each KEY=VALUE line from the seed script's stdout.
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
# 5. Boot simulator + run tests
# ---------------------------------------------------------------------------
log "booting simulator: $E2E_SIMULATOR_NAME (iOS $E2E_SIMULATOR_OS)"
# Find the device UDID. `xcrun simctl list devices` output format:
#     iPhone 16 (UUID) (State)
# macOS ships BSD awk which does not support the 3-arg match() (capture
# arrays) that GNU awk does, so we use JSON output + python to scan.
DEVICE_UDID=$(xcrun simctl list devices available --json 2>/dev/null \
    | /usr/bin/python3 -c "
import json, sys, re
data = json.load(sys.stdin)
want_os = '$E2E_SIMULATOR_OS'
want_name = '$E2E_SIMULATOR_NAME'
# Match either SimRuntime.iOS-18-6 or 'iOS 18.6'
os_key = want_os.replace('.', '-')
for runtime, devs in data.get('devices', {}).items():
    if f'iOS-{os_key}' not in runtime and f'iOS {want_os}' not in runtime:
        continue
    for d in devs:
        if not d.get('isAvailable', True):
            continue
        if d.get('name') == want_name:
            print(d['udid']); sys.exit(0)
# Fallback: any iPhone on that runtime
for runtime, devs in data.get('devices', {}).items():
    if f'iOS-{os_key}' not in runtime and f'iOS {want_os}' not in runtime:
        continue
    for d in devs:
        if not d.get('isAvailable', True):
            continue
        if 'iPhone' in d.get('name', ''):
            print(d['udid']); sys.exit(0)
" || true)
if [[ -z "$DEVICE_UDID" ]]; then
    die "no simulator matching name=$E2E_SIMULATOR_NAME os=$E2E_SIMULATOR_OS; run 'xcrun simctl list devices available'"
fi
log "using simulator UDID=$DEVICE_UDID"
xcrun simctl boot "$DEVICE_UDID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# 6. xcodebuild test
# ---------------------------------------------------------------------------
mkdir -p "$REPO_ROOT/build"
XCRESULT="$REPO_ROOT/build/e2e-results-$(date +%Y%m%d-%H%M%S).xcresult"

log "running xcodebuild test → $XCRESULT"

# The scheme's TestAction declares `EnvironmentVariables` whose values
# use `$(SMITHERS_E2E_BEARER)` etc. — xcodebuild resolves those macros
# against its own process environment at test time. So we simply export
# the values and invoke xcodebuild; no positional key=value args needed
# (those only configure build settings, not runtime env).
export SMITHERS_E2E_BEARER
export PLUE_BASE_URL
export PLUE_E2E_SEEDED=1
export PLUE_E2E_SEEDED_WORKSPACE_TITLE="${PLUE_E2E_SEEDED_WORKSPACE_TITLE:-e2e-workspace}"
export PLUE_E2E_WORKSPACE_ID
export SMITHERS_E2E_REFRESH="${SMITHERS_E2E_REFRESH:-}"
# Scenario-group inputs: terminal, approvals, reconnect. Empty values
# cause the relevant test to gracefully bail (NOT XCTSkip — an env-var
# check inside the test so the reason surfaces in the xcresult bundle).
export PLUE_E2E_WORKSPACE_SESSION_ID="${PLUE_E2E_WORKSPACE_SESSION_ID:-}"
export PLUE_E2E_AGENT_SESSION_ID="${PLUE_E2E_AGENT_SESSION_ID:-}"
export PLUE_E2E_APPROVAL_ID="${PLUE_E2E_APPROVAL_ID:-}"
export PLUE_E2E_REPO_ID="${PLUE_E2E_REPO_ID:-}"
export PLUE_E2E_REPO_OWNER="${PLUE_E2E_REPO_OWNER:-}"
export PLUE_E2E_REPO_NAME="${PLUE_E2E_REPO_NAME:-}"

# Reconnect scenario: the test asks for the docker api container name to
# `docker pause` + `docker unpause` mid-test. We discover it by prefix so
# users running a differently-named plue worktree still have their
# container picked up. When no match: the test logs why + skips.
# BSD grep (macOS) interprets some POSIX character classes differently;
# explicit ERE with -E + [0-9] works on both BSD + GNU. Match any
# container whose name ends in `-api-<digit>+`.
DOCKER_API_CONTAINER=$(docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -E -- '-api-[0-9]+$' | head -1 || true)
export PLUE_E2E_DOCKER_API_CONTAINER="${PLUE_E2E_DOCKER_API_CONTAINER:-$DOCKER_API_CONTAINER}"
log "reconnect scenario: docker api container = ${PLUE_E2E_DOCKER_API_CONTAINER:-<none found>}"

set +e
# Use a dedicated DerivedData directory so concurrent macOS-scheme
# xcodebuild invocations (e.g. the other test loop this user runs in
# parallel) cannot lock our build.db. This was a repeat source of
# `database is locked Possibly there are two concurrent builds running
# in the same filesystem location.` failures.
DERIVED_DATA="$REPO_ROOT/build/DerivedData-ios-e2e"
mkdir -p "$DERIVED_DATA"

xcodebuild \
    -project "$REPO_ROOT/SmithersGUI.xcodeproj" \
    -scheme "$E2E_SCHEME" \
    -destination "platform=iOS Simulator,id=$DEVICE_UDID,arch=arm64" \
    -resultBundlePath "$XCRESULT" \
    -derivedDataPath "$DERIVED_DATA" \
    test 2>&1 | tee "$REPO_ROOT/build/e2e-xcodebuild.log"
rc=${PIPESTATUS[0]}
set -e

if (( rc != 0 )); then
    log "xcodebuild test FAILED (rc=$rc). xcresult bundle: $XCRESULT"
    exit 1
fi

log "all E2E tests PASSED"
log "xcresult: $XCRESULT"
exit 0
