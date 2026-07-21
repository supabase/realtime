#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

N="${1:-1000}"
bench_print_args "$N"

trap bench_stop EXIT
bench_start
bench_setup_schema

bench_seed_channels $((N - 1)) 1
PGUSER=supabase_admin psql -d postgres -c "
  INSERT INTO realtime.channels (topic, broadcast_storage_enabled_at) VALUES ('news', now());
" >/dev/null

t1=$(bench_time_sql "SELECT broadcast_storage_enabled_at FROM realtime.channels WHERE topic = 'news';")

echo
{
  echo "## 6. Check since when storage is enabled"
  echo
  echo "Scenario: $N configs exist, checking since when topic \`news\` has been enabled."
  echo
  echo "Option 1: ${t1} ms"
  echo
  echo "Option 3: Not possible - pg_policy/pg_policies have no creation-timestamp column."
} | bench_print_table
