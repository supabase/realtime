#!/usr/bin/env bash
# Runs the e2e suite against stack/compose.yml, with the tenant database on one image of
# .github/db-images.json. The stack is recreated from scratch first and left running afterwards
# under the compose project e2e-<db>; `docker compose -p e2e-<db> down -v` removes it.
#
#   test/e2e/stack/run.sh <db> [realtime-check flags...]
set -euo pipefail

images=$(cd "$(dirname "$0")/../../.." && pwd)/.github/db-images.json
db=${1:?"usage: $0 <db> [realtime-check flags...], with <db> one of: $(jq -r 'keys_unsorted | join(", ")' "$images")"}
shift
cd "$(dirname "$0")"

TENANT_DB_IMAGE=$(jq -er --arg db "$db" '.[$db]' "$images") || { echo "unknown db: $db" >&2; exit 1; }
# Realtime's own database is not what is under test, so it stays on plain pg17.
POSTGRES_IMAGE=$(jq -er '.pg17' "$images")
# Published on ports docker picks, so the stack never collides with the dev databases or another stack.
export COMPOSE_PROJECT_NAME="e2e-$db" TENANT_DB_IMAGE POSTGRES_IMAGE DB_PORT=0 TENANT_DB_PORT=0

compose="docker compose -f compose.yml"
$compose down --volumes --remove-orphans
$compose build realtime
$compose up -d --wait realtime_db tenant_db
$compose run --rm tenant_db_bootstrap
$compose run --rm stack_db_bootstrap
$compose up -d --wait

gateway=$($compose port gateway 8000)
tenant_db=$($compose port tenant_db 5432)

# Supabase's well-known self-hosting demo keys, signed with the stack's JWT secret.
anon_key=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0
service_key=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0.EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU

# The fixtures put policies on realtime.messages. As postgres that takes supautils.policy_grants,
# or on images without it, membership of supabase_realtime_admin, which the committed tenant dumps
# don't carry. The first pg15 and the local Multigres image have neither, so the fixtures set up
# as supabase_admin, like the Elixir tests do. Hosted projects still exercise the postgres path.
cd ..
exec bun run realtime-check.ts --env local \
  --url "http://127.0.0.1:${gateway##*:}" \
  --db-url "postgresql://supabase_admin:postgres@127.0.0.1:${tenant_db##*:}/postgres" \
  --publishable-key "$anon_key" \
  --secret-key "$service_key" \
  "$@"
