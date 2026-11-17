#!/usr/bin/env bash
# Runs the failover harness against a local Multigres cluster, so no hosted project or cluster access is needed.
#
# It reuses the e2e stack (test/e2e/stack): Realtime built from this checkout, GoTrue, PostgREST and a gateway,
# with the tenant database on the Multigres cluster image from .github/db-images.json. A cluster with three
# cells keeps a quorum after losing a node, so an unplanned failure can be tested. All three cells run in the
# one tenant_db container, which is where the failovers are triggered.
#
#   test/failover/local.sh up                       build and start the stack, create the fixtures
#   test/failover/local.sh run planned [flags]      graceful switchover while the harness runs
#   test/failover/local.sh run unplanned [flags]    kill the primary's postgres and pooler
#   test/failover/local.sh status                   which pooler is the primary
#   test/failover/local.sh down                     remove the stack and its volumes
#
# Flags after the scenario go to failover-harness.ts. An unplanned run leaves the killed cell down, so run
# `down` and `up` again before another unplanned run (a planned run is repeatable, but the gateway only buffers
# one failover a minute, so leave a minute between runs). MT_BUFFER_ENABLED=false test/failover/local.sh up
# starts the cluster without the gateway failover buffer.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)
stack="$repo/test/e2e/stack"

images="$repo/.github/db-images.json"
export TENANT_DB_IMAGE=$(jq -er '.multigres' "$images")
export POSTGRES_IMAGE=$(jq -er '.pg17' "$images")
export COMPOSE_PROJECT_NAME=failover-multigres DB_PORT=0 TENANT_DB_PORT=0

# Supabase's well-known self-hosting demo keys, signed with the stack's JWT secret (as in test/e2e/stack/run.sh).
anon_key=$(sed -n 's/^anon_key=//p' "$stack/run.sh")
service_key=$(sed -n 's/^service_key=//p' "$stack/run.sh")

dc() { (cd "$stack" && docker compose -f compose.yml -f "$here/compose.local.yml" "$@"); }
in_db() { dc exec -T tenant_db "$@"; }

# multiadmin's HTTP API inside the container lists each pooler with its role.
poolers() { in_db curl -s localhost:15000/api/v1/poolers; }
primary() { poolers | jq -r '.poolers[] | select(.type == "PRIMARY") | "\(.id.name) \(.portMap.grpc)"'; }

case "${1:-}" in
  up)
    dc down --volumes --remove-orphans
    dc build realtime
    dc up -d --wait realtime_db tenant_db
    dc run --rm tenant_db_bootstrap
    dc run --rm stack_db_bootstrap
    dc up -d --wait
    # The e2e suite creates the tables, policies and trigger the harness reuses.
    gateway=$(dc port gateway 8000) tenant_db=$(dc port tenant_db 5432)
    (cd "$repo/test/e2e" && bun install --frozen-lockfile >/dev/null && bun run realtime-check.ts --env local \
      --url "http://127.0.0.1:${gateway##*:}" \
      --db-url "postgresql://supabase_admin:postgres@127.0.0.1:${tenant_db##*:}/postgres" \
      --publishable-key "$anon_key" --secret-key "$service_key" --test broadcast-changes)
    echo "stack is up; primary: $(primary)"
    ;;
  status)
    poolers | jq -r '.poolers[] | "\(.id.cell) \(.id.name) \(.type) \(.lifecycleStatus.status)"'
    ;;
  run)
    scenario=${2:?"usage: $0 run <planned|unplanned> [harness flags]"}
    shift 2
    case "$scenario" in
      planned)
        trigger="docker compose -p $COMPOSE_PROJECT_NAME exec -T tenant_db multigres cluster switch-primary --database=postgres --reason='failover harness' --yes --admin-server localhost:15070"
        ;;
      unplanned)
        read -r name grpc <<<"$(primary)"
        # The cell's pgctld and postgres carry its pooler directory in their arguments; the multipooler carries its gRPC port.
        # The bracketed first letter keeps pgrep from matching the shell running it.
        trigger="docker compose -p $COMPOSE_PROJECT_NAME exec -T tenant_db sh -c 'kill -9 \$(pgrep -f \"[p]ooler_$name\") \$(pgrep -f \"[m]ultipooler.*--grpc-port $grpc\")'"
        ;;
      *) echo "unknown scenario: $scenario" >&2; exit 1 ;;
    esac
    gateway=$(dc port gateway 8000) tenant_db=$(dc port tenant_db 5432)
    echo "primary before: $(primary)"
    cd "$here"
    bun install --frozen-lockfile >/dev/null
    # The harness runs the trigger itself, so the trigger time is exact. The late join is on by default.
    bun run failover-harness.ts \
      --url "http://127.0.0.1:${gateway##*:}" \
      --db-url "postgresql://supabase_admin:postgres@127.0.0.1:${tenant_db##*:}/postgres" \
      --publishable-key "$anon_key" --secret-key "$service_key" \
      --trigger-cmd "$trigger" "$@"
    echo "primary after: $(primary || true)"
    ;;
  down)
    dc down --volumes --remove-orphans
    ;;
  *)
    sed -n '2,/^set -euo/p' "$0" | sed '$d' >&2
    exit 1
    ;;
esac
