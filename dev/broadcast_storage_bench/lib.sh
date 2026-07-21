#!/usr/bin/env bash
set -euo pipefail

BENCH_CONTAINER="${BENCH_CONTAINER:-bench-broadcast-storage-pg}"
BENCH_PORT="${BENCH_PORT:-5555}"
BENCH_IMAGE="${BENCH_IMAGE:-supabase/postgres:17.6.1.127}"
BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export PGHOST=localhost PGPORT="$BENCH_PORT" PGPASSWORD=postgres

psql() { command psql -X "$@"; }

bench_start() {
  docker rm -f "$BENCH_CONTAINER" >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    docker inspect "$BENCH_CONTAINER" >/dev/null 2>&1 || break
    sleep 0.2
  done
  docker run -d --name "$BENCH_CONTAINER" -e POSTGRES_PASSWORD=postgres \
    -p "$BENCH_PORT:5432" "$BENCH_IMAGE" -c listen_addresses='*' >/dev/null
  echo "waiting for postgres on port $BENCH_PORT..." >&2
  for _ in $(seq 1 30); do
    PGUSER=supabase_admin psql -d postgres -c 'select 1' >/dev/null 2>&1 && return 0
    sleep 1
  done
  echo "postgres did not become ready in time" >&2
  exit 1
}

bench_stop() {
  docker rm -f "$BENCH_CONTAINER" >/dev/null 2>&1 || true
}

bench_setup_schema() {
  PGUSER=supabase_admin psql -d postgres -v ON_ERROR_STOP=1 -f "$BENCH_DIR/00_setup_opt1.sql" >/dev/null
  PGUSER=supabase_admin psql -d postgres -v ON_ERROR_STOP=1 -f "$BENCH_DIR/00_setup_opt3.sql" >/dev/null
}

bench_seed_channels() {
  local n=$1 start=${2:-1}
  local end=$((start + n - 1))
  PGUSER=supabase_admin psql -d postgres -c "
    INSERT INTO realtime.channels (topic, broadcast_storage_enabled_at)
    SELECT 'topic:' || i, now() FROM generate_series($start, $end) i;
  " >/dev/null
}

bench_seed_messages() {
  local table=$1 n=$2 topic=${3:-news}
  PGUSER=supabase_admin psql -d postgres -c "
    INSERT INTO $table (topic, extension, payload, event, private)
    SELECT '$topic', 'broadcast', '{\"msg\": \"seed\"}'::jsonb, 'event', true
    FROM generate_series(1, $n);
  " >/dev/null
}

bench_create_policies() {
  local start=$1 end=$2 secs=${3:-300}
  local rc=0 out tmpfile
  tmpfile=$(mktemp)
  cat >"$tmpfile" <<SQL
\timing on
DO \$\$
DECLARE i int;
BEGIN
  FOR i IN ${start}..${end} LOOP
    EXECUTE format(
      'CREATE POLICY "allow_topic_%s" ON realtime.messages_opt3 AS PERMISSIVE FOR INSERT TO bench_writer3 WITH CHECK (extension = ''broadcast'' AND topic = ''topic:%s'')',
      i, i
    );
  END LOOP;
END \$\$;
SQL
  out=$(timeout "$secs" psql -h "$PGHOST" -p "$PGPORT" -U supabase_admin -d postgres -f "$tmpfile" 2>&1) || rc=$?
  rm -f "$tmpfile"
  if [ "$rc" -eq 124 ]; then
    echo "  -> timed out after ${secs}s, terminating backend server-side" >&2
    local pid
    pid=$(psql -U supabase_admin -d postgres -tAc \
      "SELECT pid FROM pg_stat_activity WHERE datname='postgres' AND pid <> pg_backend_pid() AND state='active' LIMIT 1")
    [ -n "$pid" ] && psql -U supabase_admin -d postgres -c "SELECT pg_terminate_backend($pid);" >/dev/null
    return 124
  elif [ "$rc" -ne 0 ]; then
    echo "  -> failed (exit $rc): $out" >&2
    return "$rc"
  fi
  echo "$out" | grep -oE "Time: [0-9.]+ ms" | tail -1 | grep -oE "[0-9.]+"
  return 0
}

bench_policy_count() {
  PGUSER=supabase_admin psql -d postgres -tAc \
    "SELECT count(*) FROM pg_policies WHERE schemaname='realtime' AND tablename='messages_opt3';"
}

bench_time_sql() {
  local sql=$1
  PGUSER=supabase_admin psql -d postgres <<SQL 2>&1 | grep -oE "Time: [0-9.]+ ms" | tail -1 | grep -oE "[0-9.]+"
\timing on
$sql
SQL
}

bench_pgbench_latency() {
  local role=$1 file=$2 t=${3:-200} c=${4:-1}
  pgbench -h "$PGHOST" -p "$PGPORT" -U "$role" -d postgres -n -t "$t" -c "$c" -f "$file" 2>&1 |
    grep -E "latency average" | grep -oE "[0-9.]+ ms" | grep -oE "[0-9.]+"
}

bench_relation_size() {
  local rel=$1
  PGUSER=supabase_admin psql -d postgres -tAc "SELECT pg_total_relation_size('$rel');"
}

bench_pct() {
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%+.1f%%", (b - a) / a * 100 }'
}

bench_print_args() {
  echo "\$ $(basename "$0") $*"
  echo
}

bench_print_table() {
  if command -v glow >/dev/null 2>&1; then
    glow -
  else
    cat
  fi
}
