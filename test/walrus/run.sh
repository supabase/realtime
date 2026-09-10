#!/usr/bin/env bash
#
# Runs the WALRUS pg_regress suite against the committed tenant DB dump.
#
# The suite came from the (now retired) supabase/walrus repo. Instead of building the
# `realtime` schema from walrus' own migration files, it loads
# priv/repo/tenant_db_dump_<major>.sql -- the same dump `Realtime.Tenants.Migrations`
# hands a fresh tenant -- so these are regression tests for the schema we ship.
#
#   test/walrus/run.sh                     # every test
#   test/walrus/run.sh test_simple_insert  # named tests, passed through to pg_regress
#   POSTGRES_IMAGE=supabase/postgres:15.14.1.167 test/walrus/run.sh
#   POSTGRES_IMAGE=supabase/postgres:17.9.0.019-orioledb test/walrus/run.sh
#
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

COMPOSE=(docker compose -f compose.walrus-db.yml)
trap '"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true' EXIT

# A cluster left over from an interrupted run already has the schema loaded.
"${COMPOSE[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
"${COMPOSE[@]}" up -d --wait

set +e
"${COMPOSE[@]}" exec -T -u postgres walrus_db bash -s -- "$@" <<'INNER'
set -euo pipefail
export PGUSER=supabase_admin PGDATABASE=postgres PG_COLOR=auto

major=$(psql -Atqc "select current_setting('server_version_num')::int / 10000")
echo "# loading tenant_db_dump_${major}.sql"
psql -v ON_ERROR_STOP=1 -q -f "/walrus/priv/repo/tenant_db_dump_${major}.sql" >/dev/null
psql -v ON_ERROR_STOP=1 -q -f /walrus/test/setup.sql -f /walrus/test/fixtures.sql >/dev/null

# The tests share one database and run in the order given, so sort for a stable order.
tests=("$@")
if [ $# -eq 0 ]; then
  tests=($(ls /walrus/test/sql | sed 's/\.sql$//' | sort))
fi

rm -rf /tmp/walrus-out
exec "$(dirname "$(pg_config --pgxs)")/../test/regress/pg_regress" \
  --use-existing --dbname="$PGDATABASE" \
  --inputdir=/walrus/test --outputdir=/tmp/walrus-out \
  "${tests[@]}"
INNER
status=$?
set -e

# What actually happened, kept on the host like walrus did. To accept a diff:
# cp test/walrus/results/<test>.out test/walrus/expected/<test>.out
rm -rf test/walrus/results
docker cp "$("${COMPOSE[@]}" ps -q walrus_db):/tmp/walrus-out/results" test/walrus/results >/dev/null 2>&1 || true

if [ $status -ne 0 ]; then
  echo
  "${COMPOSE[@]}" exec -T walrus_db cat /tmp/walrus-out/regression.diffs 2>/dev/null || true
fi

exit $status
