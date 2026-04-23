#!/usr/bin/env bash
# ios/scripts/seed-e2e-data.sh — idempotent SQL seed for the iOS E2E
# harness.
#
# Ticket: ios-e2e-harness. Writes a known user + access token + repository
# + workspace row into a running plue Postgres instance so the XCUITest
# suite has real server state to exercise.
#
# Token contract: prefix `jjhub_e2e_` followed by 32 hex chars. The value
# is generated each run (NEVER hardcoded in tests) and exported via env
# so `run-e2e.sh` can thread it into xcodebuild's test environment.
#
# Idempotency: every INSERT uses ON CONFLICT DO UPDATE so re-running does
# not error out. The seeded user/repo/workspace are namespaced with
# `e2e-` prefixes so they never collide with existing dev seed rows.
#
# Required env:
#   PGHOST           (default: 127.0.0.1)
#   PGPORT           (default: 5432)
#   PGUSER           (default: jjhub)
#   PGPASSWORD       (default: jjhub)
#   PGDATABASE       (default: jjhub)
#
# Outputs (to stdout, as key=value, so the caller can `eval` them):
#   SMITHERS_E2E_BEARER=<token string>
#   PLUE_E2E_USER_ID=<integer>
#   PLUE_E2E_WORKSPACE_ID=<uuid>
#   PLUE_E2E_SEEDED_WORKSPACE_TITLE=<title>

set -euo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGPORT:=5432}"
: "${PGUSER:=jjhub}"
: "${PGPASSWORD:=jjhub}"
: "${PGDATABASE:=jjhub}"

export PGPASSWORD

# Generate a fresh token per run. Prefix distinguishes from prod tokens
# so a leak is easy to detect in logs.
if [[ -n "${SMITHERS_E2E_BEARER:-}" ]]; then
  TOKEN="$SMITHERS_E2E_BEARER"
else
  HEX="$(openssl rand -hex 16)"
  TOKEN="jjhub_e2e_${HEX}"
fi

WORKSPACE_TITLE="${PLUE_E2E_SEEDED_WORKSPACE_TITLE:-e2e-workspace}"

PSQL=(psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" -v ON_ERROR_STOP=1 -tA)

# Wait for postgres to accept queries. Cap at 60s — if it's not up by
# then something is wrong with `make docker-up`.
deadline=$((SECONDS + 60))
until "${PSQL[@]}" -c 'SELECT 1' >/dev/null 2>&1; do
  if (( SECONDS >= deadline )); then
    echo "seed-e2e-data.sh: postgres not reachable at $PGHOST:$PGPORT after 60s" >&2
    exit 1
  fi
  sleep 1
done

# The E2E user lives in the same `users` table as the dev seed user, but
# with a distinct username so the two do not collide. We piggyback on
# alice's organization for relation sanity; if the seeded dev rows are
# absent this script will fail loudly (which is what we want — the seed
# should have run as part of docker compose up).
SQL=$(cat <<SQL
DO \$\$
DECLARE
    v_user_id        BIGINT;
    v_workspace_id   UUID;
    v_repo_id        BIGINT;
BEGIN
    -- Ensure the E2E user exists. The 'alice' dev user from db/seed.sql
    -- provides the org; we reuse its organization_id if the schema
    -- requires an organization, but otherwise keep the user independent.
    INSERT INTO users (username, lower_username, email, password_hash, is_admin, created_at, updated_at)
    VALUES (
        'e2e_user',
        'e2e_user',
        'e2e@smithers.local',
        'x',
        FALSE,
        NOW(),
        NOW()
    )
    ON CONFLICT (lower_username) DO UPDATE
        SET email = EXCLUDED.email,
            updated_at = NOW()
    RETURNING id INTO v_user_id;

    -- Access token. We use a deterministic id (9000) that is well above
    -- the dev seed IDs (1-3) so we never collide and so multiple e2e
    -- runs update the same row.
    INSERT INTO access_tokens (id, user_id, name, token_hash, token_last_eight, scopes, created_at, updated_at)
    VALUES (
        9000,
        v_user_id,
        'e2e-ios-harness',
        encode(digest('$TOKEN', 'sha256'), 'hex'),
        RIGHT('$TOKEN', 8),
        'write:repository,read:repository,write:user,read:user,write:workspace,read:workspace',
        NOW(),
        NOW()
    )
    ON CONFLICT (id) DO UPDATE
        SET user_id = EXCLUDED.user_id,
            token_hash = EXCLUDED.token_hash,
            token_last_eight = EXCLUDED.token_last_eight,
            scopes = EXCLUDED.scopes,
            updated_at = NOW();

    -- Repository owned by our e2e user.
    INSERT INTO repositories (user_id, name, lower_name, description, visibility, created_at, updated_at)
    VALUES (
        v_user_id,
        'e2e-repo',
        'e2e-repo',
        'seeded by ios/scripts/seed-e2e-data.sh',
        'private',
        NOW(),
        NOW()
    )
    ON CONFLICT (user_id, lower_name) DO UPDATE
        SET description = EXCLUDED.description,
            updated_at = NOW()
    RETURNING id INTO v_repo_id;

    -- Workspace: idempotent via a stable UUID derived from the repo+user
    -- tuple. `uuid-ossp` is commonly installed; fall back to a fixed
    -- UUID namespace + digest if not.
    INSERT INTO workspaces (id, repository_id, user_id, name, status, last_activity_at, created_at, updated_at)
    VALUES (
        'e2e00000-0000-0000-0000-000000000001',
        v_repo_id,
        v_user_id,
        '$WORKSPACE_TITLE',
        'running',
        NOW(),
        NOW(),
        NOW()
    )
    ON CONFLICT (id) DO UPDATE
        SET name = EXCLUDED.name,
            status = EXCLUDED.status,
            last_activity_at = NOW(),
            updated_at = NOW()
    RETURNING id INTO v_workspace_id;

    RAISE NOTICE 'SEED_USER_ID=%', v_user_id;
    RAISE NOTICE 'SEED_WORKSPACE_ID=%', v_workspace_id;
END
\$\$ LANGUAGE plpgsql;
SQL
)

# `psql` sends RAISE NOTICE output to stderr. Capture both streams so we
# can extract the ids and still surface errors to the caller.
set +e
OUT=$("${PSQL[@]}" -c "$SQL" 2>&1)
rc=$?
set -e
if (( rc != 0 )); then
    echo "$OUT" >&2
    echo "seed-e2e-data.sh: psql failed with exit $rc" >&2
    exit "$rc"
fi

user_id=$(echo "$OUT" | sed -n 's/.*SEED_USER_ID=\([0-9]*\).*/\1/p' | head -1)
workspace_id=$(echo "$OUT" | sed -n 's/.*SEED_WORKSPACE_ID=\([0-9a-f-]*\).*/\1/p' | head -1)

if [[ -z "$user_id" || -z "$workspace_id" ]]; then
    echo "seed-e2e-data.sh: failed to parse user/workspace id from psql output" >&2
    echo "$OUT" >&2
    exit 1
fi

cat <<ENV
SMITHERS_E2E_BEARER=$TOKEN
PLUE_E2E_USER_ID=$user_id
PLUE_E2E_WORKSPACE_ID=$workspace_id
PLUE_E2E_SEEDED_WORKSPACE_TITLE=$WORKSPACE_TITLE
ENV
