#!/usr/bin/env bash
# End-to-end backend happy-path smoke test for a running plue stack.
#
# This intentionally does not start plue. It only verifies that the API and
# Postgres-backed seed path are reachable, seeds deterministic E2E data via
# seed-e2e-data.sh, then exercises the server-side happy path with curl.

set -u
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

BASE_URL="${PLUE_BASE_URL:-http://localhost:4000}"
while [[ "$BASE_URL" == */ ]]; do
    BASE_URL="${BASE_URL%/}"
done
if [[ "$BASE_URL" == */api ]]; then
    BASE_URL="${BASE_URL%/api}"
fi

export PATH="/opt/homebrew/opt/libpq/bin:/opt/homebrew/bin:/usr/local/bin:${PATH}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/smithers-happy-path-smoke.XXXXXX")"
CREATED_REPO_OWNER=""
CREATED_REPO_NAME=""
CREATED_WORKSPACE_ID=""
CREATED_AGENT_SESSION_ID=""
LAST_HTTP_CODE=""
LAST_CURL_RC=0
LAST_CURL_ERR=""
DEVTOOLS_MARKER=""
DEVTOOLS_WRITE_OK=0

cleanup() {
    local rc=$?
    if [[ -n "$CREATED_AGENT_SESSION_ID" && -n "$CREATED_REPO_OWNER" && -n "$CREATED_REPO_NAME" && -n "${SMITHERS_E2E_BEARER:-}" ]]; then
        curl -sS -o /dev/null -X DELETE \
            -H "Authorization: Bearer $SMITHERS_E2E_BEARER" \
            "$BASE_URL/api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/agent/sessions/$CREATED_AGENT_SESSION_ID" \
            >/dev/null 2>&1 || true
    fi
    if [[ -n "$CREATED_WORKSPACE_ID" && -n "$CREATED_REPO_OWNER" && -n "$CREATED_REPO_NAME" && -n "${SMITHERS_E2E_BEARER:-}" ]]; then
        curl -sS -o /dev/null -X DELETE \
            -H "Authorization: Bearer $SMITHERS_E2E_BEARER" \
            "$BASE_URL/api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/workspaces/$CREATED_WORKSPACE_ID" \
            >/dev/null 2>&1 || true
    fi
    if [[ -n "$CREATED_REPO_OWNER" && -n "$CREATED_REPO_NAME" && -n "${SMITHERS_E2E_BEARER:-}" ]]; then
        curl -sS -o /dev/null -X DELETE \
            -H "Authorization: Bearer $SMITHERS_E2E_BEARER" \
            "$BASE_URL/api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME" \
            >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP_DIR"
    exit "$rc"
}
trap cleanup EXIT

snippet() {
    local file="$1"
    if [[ ! -s "$file" ]]; then
        echo "<empty>"
        return
    fi
    /usr/bin/python3 - "$file" <<'PY'
import json
import sys

path = sys.argv[1]
raw = open(path, "rb").read()
text = raw.decode("utf-8", "replace")
try:
    text = json.dumps(json.loads(text), separators=(",", ":"), sort_keys=True)
except Exception:
    text = " ".join(text.split())
if len(text) > 320:
    text = text[:317] + "..."
print(text)
PY
}

fail_setup() {
    echo "SETUP: FAIL - $1" >&2
    if [[ $# -gt 1 && -n "$2" ]]; then
        echo "$2" >&2
    fi
    exit 2
}

pass_step() {
    local step="$1"
    local message="$2"
    local file="$3"
    echo "STEP $step: PASS - $message | $(snippet "$file")"
}

fail_step() {
    local step="$1"
    local message="$2"
    local file="${3:-}"
    if [[ -n "$file" && -f "$file" ]]; then
        echo "STEP $step: FAIL - $message | $(snippet "$file")" >&2
    else
        echo "STEP $step: FAIL - $message" >&2
    fi
    if [[ -n "$LAST_CURL_ERR" ]]; then
        echo "curl: $LAST_CURL_ERR" >&2
    fi
    exit 1
}

api_request() {
    local method="$1"
    local path="$2"
    local body="$3"
    local out="$4"
    local timeout="${5:-30}"
    local trimmed="${path#/}"
    local err="$TMP_DIR/curl.err"
    local args

    : > "$err"
    args=(
        -sS
        --connect-timeout 5
        --max-time "$timeout"
        -o "$out"
        -w "%{http_code}"
        -X "$method"
        -H "Accept: application/json"
        -H "Authorization: Bearer $SMITHERS_E2E_BEARER"
    )
    if [[ -n "$body" ]]; then
        args+=(-H "Content-Type: application/json" --data "$body")
    fi

    LAST_HTTP_CODE="$(curl "${args[@]}" "$BASE_URL/$trimmed" 2>"$err")"
    LAST_CURL_RC=$?
    LAST_CURL_ERR="$(cat "$err")"
}

json_tool() {
    /usr/bin/python3 - "$@" <<'PY'
import json
import sys

mode = sys.argv[1]
path = sys.argv[2]
args = sys.argv[3:]
raw = open(path, "rb").read()
try:
    obj = json.loads(raw.decode("utf-8") if raw else "null")
except Exception as exc:
    print(f"invalid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

def fail(message):
    print(message, file=sys.stderr)
    sys.exit(1)

def rows(value, keys):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):
        for key in keys:
            child = value.get(key)
            if isinstance(child, list):
                return child
    return []

def first_value(value, keys):
    if not isinstance(value, dict):
        return None
    candidates = [value]
    for key in ("repo", "repository", "workspace", "session", "data"):
        if isinstance(value.get(key), dict):
            candidates.append(value[key])
    for candidate in candidates:
        for key in keys:
            found = candidate.get(key)
            if found not in (None, ""):
                return found
    return None

def contains(value, needle):
    if isinstance(value, str):
        return value == needle or needle in value
    if isinstance(value, list):
        return any(contains(item, needle) for item in value)
    if isinstance(value, dict):
        return any(contains(item, needle) for item in value.values())
    return False

def normalize_state(raw):
    raw = str(raw).strip().lower()
    if raw in ("approve", "approved"):
        return "approved"
    if raw in ("deny", "denied", "reject", "rejected"):
        return "denied"
    return raw

def flatten_approvals(value):
    output = []
    if isinstance(value, list):
        for item in value:
            output.extend(flatten_approvals(item))
    elif isinstance(value, dict):
        approval_id = value.get("id") or value.get("approval_id")
        state = value.get("state") or value.get("status")
        if approval_id and state:
            output.append((str(approval_id), normalize_state(state)))
        for key in ("approvals", "items", "results", "data"):
            child = value.get(key)
            if child is not None:
                output.extend(flatten_approvals(child))
    return output

if mode == "user":
    if isinstance(obj, dict) and first_value(obj, ["id", "username", "email", "display_name"]):
        print(first_value(obj, ["id", "username", "email", "display_name"]))
        sys.exit(0)
    fail("expected user JSON object")

if mode == "count":
    found = rows(obj, args)
    print(len(found))
    if len(found) < 1:
        fail("expected at least one row")
    sys.exit(0)

if mode == "extract":
    value = first_value(obj, args)
    if value is None:
        fail(f"missing any of: {', '.join(args)}")
    print(value)
    sys.exit(0)

if mode == "contains":
    needle = args[0]
    if contains(obj, needle):
        print("1")
        sys.exit(0)
    fail(f"missing marker: {needle}")

if mode == "approval_state":
    target = args[0].lower()
    for approval_id, state in flatten_approvals(obj):
        if approval_id.lower() == target:
            print(state)
            sys.exit(0)
    fail(f"approval {target} missing from payload")

fail(f"unknown mode: {mode}")
PY
}

require_http() {
    local step="$1"
    local expected="$2"
    local context="$3"
    local file="$4"
    if [[ "$LAST_CURL_RC" -ne 0 ]]; then
        fail_step "$step" "$context curl failed with exit $LAST_CURL_RC" "$file"
    fi
    if [[ "$LAST_HTTP_CODE" != "$expected" ]]; then
        fail_step "$step" "$context returned HTTP $LAST_HTTP_CODE, expected $expected" "$file"
    fi
}

preflight_api() {
    local out="$TMP_DIR/preflight.json"
    local err="$TMP_DIR/preflight.err"
    local code

    code="$(curl -sS --connect-timeout 3 --max-time 8 -o "$out" -w "%{http_code}" "$BASE_URL/api/feature-flags" 2>"$err")"
    local rc=$?
    if [[ "$rc" -ne 0 || "$code" == "000" ]]; then
        fail_setup "plue API is not reachable at $BASE_URL; start the stack first" "$(cat "$err")"
    fi
}

seed_e2e_data() {
    local seed_err="$TMP_DIR/seed.err"
    local seed_out

    if [[ ! -x "$SCRIPT_DIR/seed-e2e-data.sh" ]]; then
        fail_setup "missing executable seed script: $SCRIPT_DIR/seed-e2e-data.sh"
    fi

    seed_out="$("$SCRIPT_DIR/seed-e2e-data.sh" 2>"$seed_err")"
    local rc=$?
    if [[ "$rc" -ne 0 ]]; then
        fail_setup "seed-e2e-data.sh failed; the running stack or Postgres seed is not ready" "$(cat "$seed_err")"
    fi

    while IFS='=' read -r key value; do
        [[ -z "$key" ]] && continue
        export "$key=$value"
    done <<< "$seed_out"

    if [[ -z "${SMITHERS_E2E_BEARER:-}" || -z "${PLUE_E2E_REPO_OWNER:-}" || -z "${PLUE_E2E_REPO_NAME:-}" || -z "${PLUE_E2E_APPROVAL_ID:-}" ]]; then
        fail_setup "seed-e2e-data.sh did not emit the required bearer/repo/approval values"
    fi
}

create_temp_repo() {
    local out="$TMP_DIR/setup-create-repo.json"
    local suffix
    suffix="$(date +%s)-$$-$RANDOM"
    local repo_name="happy-path-smoke-$suffix"
    local body
    body="$(printf '{"name":"%s","description":"created by ios/scripts/happy-path-smoke.sh","private":true,"auto_init":true,"default_bookmark":"main"}' "$repo_name")"

    api_request "POST" "api/user/repos" "$body" "$out" 60
    if [[ "$LAST_CURL_RC" -ne 0 ]]; then
        fail_setup "temporary repo creation curl failed" "$LAST_CURL_ERR"
    fi
    if [[ "$LAST_HTTP_CODE" != "201" ]]; then
        fail_setup "temporary repo creation returned HTTP $LAST_HTTP_CODE; expected 201" "$(snippet "$out")"
    fi

    CREATED_REPO_OWNER="$(json_tool extract "$out" owner repo_owner repository_owner namespace organization org 2>/dev/null || true)"
    CREATED_REPO_NAME="$(json_tool extract "$out" name repo_name repository_name slug 2>/dev/null || true)"
    if [[ -z "$CREATED_REPO_OWNER" ]]; then
        CREATED_REPO_OWNER="$PLUE_E2E_REPO_OWNER"
    fi
    if [[ -z "$CREATED_REPO_NAME" ]]; then
        CREATED_REPO_NAME="$repo_name"
    fi
    TEMP_REPO_ID="$(json_tool extract "$out" id repository_id repo_id 2>/dev/null || true)"
    echo "SETUP: PASS - created temporary repo $CREATED_REPO_OWNER/$CREATED_REPO_NAME | $(snippet "$out")"
}

try_write_devtools_snapshot() {
    [[ -z "$CREATED_AGENT_SESSION_ID" ]] && return

    local out="$TMP_DIR/setup-devtools-post.json"
    local marker="happy-path-smoke-devtools-$(date +%s)-$RANDOM"
    DEVTOOLS_MARKER="$marker"
    local body
    if [[ -n "${TEMP_REPO_ID:-}" && "$TEMP_REPO_ID" =~ ^[0-9]+$ ]]; then
        body="$(printf '{"session_id":"%s","repository_id":%s,"kind":"command_output","payload":{"marker":"%s","line":"happy path smoke"}}' "$CREATED_AGENT_SESSION_ID" "$TEMP_REPO_ID" "$marker")"
    else
        body="$(printf '{"session_id":"%s","kind":"command_output","payload":{"marker":"%s","line":"happy path smoke"}}' "$CREATED_AGENT_SESSION_ID" "$marker")"
    fi

    local candidates=(
        "api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/devtools/snapshots"
        "api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/devtools-snapshots"
        "api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/devtools_snapshots"
        "api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/agent/sessions/$CREATED_AGENT_SESSION_ID/devtools/snapshots"
        "api/agent/sessions/$CREATED_AGENT_SESSION_ID/devtools/snapshots"
        "api/devtools/snapshots"
    )

    local path
    for path in "${candidates[@]}"; do
        api_request "POST" "$path" "$body" "$out" 30
        if [[ "$LAST_CURL_RC" -ne 0 ]]; then
            continue
        fi
        case "$LAST_HTTP_CODE" in
            201)
                DEVTOOLS_WRITE_OK=1
                echo "SETUP: PASS - wrote devtools command_output snapshot via /$path | $(snippet "$out")"
                return
                ;;
            404|405|501)
                continue
                ;;
            *)
                echo "SETUP: SKIP - devtools snapshot write via /$path returned HTTP $LAST_HTTP_CODE | $(snippet "$out")"
                return
                ;;
        esac
    done

    echo "SETUP: SKIP - no devtools snapshot write endpoint accepted the setup POST"
}

preflight_api
seed_e2e_data

# 1. GET /api/user -> 200 with user json.
STEP_OUT="$TMP_DIR/step-1-user.json"
api_request "GET" "api/user" "" "$STEP_OUT"
require_http 1 200 "GET /api/user" "$STEP_OUT"
if ! json_tool user "$STEP_OUT" >/dev/null 2>"$TMP_DIR/step-1-json.err"; then
    fail_step 1 "GET /api/user did not return a user JSON object: $(cat "$TMP_DIR/step-1-json.err")" "$STEP_OUT"
fi
pass_step 1 "GET /api/user returned user JSON" "$STEP_OUT"

# 2. GET /api/user/repos -> 200 with >= 1 repo.
STEP_OUT="$TMP_DIR/step-2-repos.json"
api_request "GET" "api/user/repos" "" "$STEP_OUT"
require_http 2 200 "GET /api/user/repos" "$STEP_OUT"
repo_count="$(json_tool count "$STEP_OUT" repos repositories items results data 2>"$TMP_DIR/step-2-json.err")" || \
    fail_step 2 "GET /api/user/repos did not contain at least one repo: $(cat "$TMP_DIR/step-2-json.err")" "$STEP_OUT"
pass_step 2 "GET /api/user/repos returned $repo_count repo(s)" "$STEP_OUT"

# 3. GET /api/user/workspaces -> 200 with >= 1 workspace.
STEP_OUT="$TMP_DIR/step-3-workspaces.json"
api_request "GET" "api/user/workspaces?limit=100" "" "$STEP_OUT"
require_http 3 200 "GET /api/user/workspaces" "$STEP_OUT"
workspace_count="$(json_tool count "$STEP_OUT" workspaces items results data 2>"$TMP_DIR/step-3-json.err")" || \
    fail_step 3 "GET /api/user/workspaces did not contain at least one workspace: $(cat "$TMP_DIR/step-3-json.err")" "$STEP_OUT"
pass_step 3 "GET /api/user/workspaces returned $workspace_count workspace(s)" "$STEP_OUT"

create_temp_repo

# 4. POST /api/repos/{o}/{r}/workspaces -> 201 with new workspace id.
STEP_OUT="$TMP_DIR/step-4-create-workspace.json"
workspace_name="happy-path-smoke-workspace-$(date +%s)-$RANDOM"
api_request "POST" "api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/workspaces" "{\"name\":\"$workspace_name\"}" "$STEP_OUT" 120
require_http 4 201 "POST /api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/workspaces" "$STEP_OUT"
CREATED_WORKSPACE_ID="$(json_tool extract "$STEP_OUT" id workspace_id 2>"$TMP_DIR/step-4-json.err")" || \
    fail_step 4 "workspace create response did not include an id: $(cat "$TMP_DIR/step-4-json.err")" "$STEP_OUT"
pass_step 4 "created workspace id $CREATED_WORKSPACE_ID" "$STEP_OUT"

# 5. GET /api/repos/{o}/{r}/workspaces/{id} -> 200 with workspace details.
STEP_OUT="$TMP_DIR/step-5-get-workspace.json"
api_request "GET" "api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/workspaces/$CREATED_WORKSPACE_ID" "" "$STEP_OUT"
require_http 5 200 "GET /api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/workspaces/$CREATED_WORKSPACE_ID" "$STEP_OUT"
fetched_workspace_id="$(json_tool extract "$STEP_OUT" id workspace_id 2>"$TMP_DIR/step-5-json.err")" || \
    fail_step 5 "workspace detail response did not include an id: $(cat "$TMP_DIR/step-5-json.err")" "$STEP_OUT"
if [[ "$fetched_workspace_id" != "$CREATED_WORKSPACE_ID" ]]; then
    fail_step 5 "workspace detail id $fetched_workspace_id did not match created id $CREATED_WORKSPACE_ID" "$STEP_OUT"
fi
pass_step 5 "fetched workspace details for $CREATED_WORKSPACE_ID" "$STEP_OUT"

# 6. POST /api/repos/{o}/{r}/agent/sessions -> 201 creating a session.
STEP_OUT="$TMP_DIR/step-6-create-session.json"
session_title="happy-path-smoke-session-$(date +%s)-$RANDOM"
api_request "POST" "api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/agent/sessions" "{\"title\":\"$session_title\"}" "$STEP_OUT"
require_http 6 201 "POST /api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/agent/sessions" "$STEP_OUT"
CREATED_AGENT_SESSION_ID="$(json_tool extract "$STEP_OUT" id session_id 2>"$TMP_DIR/step-6-json.err")" || \
    fail_step 6 "agent session create response did not include an id: $(cat "$TMP_DIR/step-6-json.err")" "$STEP_OUT"
pass_step 6 "created agent session id $CREATED_AGENT_SESSION_ID" "$STEP_OUT"

# 7. POST /api/repos/{o}/{r}/agent/sessions/{id}/messages -> 201 append user message.
STEP_OUT="$TMP_DIR/step-7-post-message.json"
MESSAGE_TEXT="happy-path-smoke-message-$(date +%s)-$RANDOM"
message_body="$(printf '{"role":"user","parts":[{"type":"text","content":"%s"}]}' "$MESSAGE_TEXT")"
api_request "POST" "api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/agent/sessions/$CREATED_AGENT_SESSION_ID/messages" "$message_body" "$STEP_OUT"
require_http 7 201 "POST /api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/agent/sessions/$CREATED_AGENT_SESSION_ID/messages" "$STEP_OUT"
pass_step 7 "appended user message $MESSAGE_TEXT" "$STEP_OUT"

# 8. GET /api/repos/{o}/{r}/agent/sessions/{id}/messages -> 200 with appended message.
STEP_OUT="$TMP_DIR/step-8-get-messages.json"
deadline=$((SECONDS + 10))
while true; do
    api_request "GET" "api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/agent/sessions/$CREATED_AGENT_SESSION_ID/messages" "" "$STEP_OUT"
    require_http 8 200 "GET /api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/agent/sessions/$CREATED_AGENT_SESSION_ID/messages" "$STEP_OUT"
    if json_tool contains "$STEP_OUT" "$MESSAGE_TEXT" >/dev/null 2>"$TMP_DIR/step-8-json.err"; then
        pass_step 8 "GET /messages returned appended message" "$STEP_OUT"
        break
    fi
    if (( SECONDS >= deadline )); then
        fail_step 8 "GET /messages never included $MESSAGE_TEXT: $(cat "$TMP_DIR/step-8-json.err")" "$STEP_OUT"
    fi
    sleep 1
done

# 9. GET /api/repos/{o}/{r}/approvals -> 200 (empty or seeded).
STEP_OUT="$TMP_DIR/step-9-approvals.json"
api_request "GET" "api/repos/$PLUE_E2E_REPO_OWNER/$PLUE_E2E_REPO_NAME/approvals" "" "$STEP_OUT"
require_http 9 200 "GET /api/repos/$PLUE_E2E_REPO_OWNER/$PLUE_E2E_REPO_NAME/approvals" "$STEP_OUT"
pass_step 9 "GET /approvals returned 200 for seeded repo" "$STEP_OUT"

# 10. POST /api/repos/{o}/{r}/approvals/{seeded-id}/decide -> 200, state transitions.
STEP_OUT="$TMP_DIR/step-10-decide.json"
api_request "POST" "api/repos/$PLUE_E2E_REPO_OWNER/$PLUE_E2E_REPO_NAME/approvals/$PLUE_E2E_APPROVAL_ID/decide" '{"decision":"approved"}' "$STEP_OUT"
require_http 10 200 "POST /api/repos/$PLUE_E2E_REPO_OWNER/$PLUE_E2E_REPO_NAME/approvals/$PLUE_E2E_APPROVAL_ID/decide" "$STEP_OUT"
VERIFY_OUT="$TMP_DIR/step-10-verify.json"
api_request "GET" "api/repos/$PLUE_E2E_REPO_OWNER/$PLUE_E2E_REPO_NAME/approvals" "" "$VERIFY_OUT"
require_http 10 200 "GET /approvals after decide" "$VERIFY_OUT"
approval_state="$(json_tool approval_state "$VERIFY_OUT" "$PLUE_E2E_APPROVAL_ID" 2>"$TMP_DIR/step-10-json.err")" || \
    fail_step 10 "decided approval was not present after transition: $(cat "$TMP_DIR/step-10-json.err")" "$VERIFY_OUT"
if [[ "$approval_state" != "approved" ]]; then
    fail_step 10 "approval state was $approval_state after decide, expected approved" "$VERIFY_OUT"
fi
pass_step 10 "seeded approval transitioned to approved" "$STEP_OUT"

try_write_devtools_snapshot

# 11. GET /api/repos/{o}/{r}/devtools/snapshots/latest?session_id=...&kind=command_output -> 200.
STEP_OUT="$TMP_DIR/step-11-devtools-latest.json"
api_request "GET" "api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/devtools/snapshots/latest?session_id=$CREATED_AGENT_SESSION_ID&kind=command_output" "" "$STEP_OUT"
require_http 11 200 "GET /api/repos/$CREATED_REPO_OWNER/$CREATED_REPO_NAME/devtools/snapshots/latest?session_id=...&kind=command_output" "$STEP_OUT"
if [[ "$DEVTOOLS_WRITE_OK" == "1" ]]; then
    json_tool contains "$STEP_OUT" "$DEVTOOLS_MARKER" >/dev/null 2>"$TMP_DIR/step-11-json.err" || \
        fail_step 11 "latest devtools response did not include marker $DEVTOOLS_MARKER: $(cat "$TMP_DIR/step-11-json.err")" "$STEP_OUT"
fi
pass_step 11 "GET latest command_output snapshot returned 200" "$STEP_OUT"

# 12 is optional. The system curl on macOS currently lacks ws/wss protocol
# support, so keep this smoke deterministic without bringing in another tool.
if curl --version | sed -n '/^Protocols:/p' | grep -Eq '(^| )wss?( |$)'; then
    echo "STEP 12: SKIP - optional PTY websocket probe not enabled by default"
else
    echo "STEP 12: SKIP - optional PTY websocket probe requires a curl build with ws/wss protocol support"
fi
