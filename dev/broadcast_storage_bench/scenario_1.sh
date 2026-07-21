#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

if [ "$#" -gt 0 ]; then
  SCALES=("$@")
else
  SCALES=(${SCALES:-1000 10000 100000 1000000})
fi
bench_print_args "${SCALES[@]}"

trap bench_stop EXIT
bench_start
bench_setup_schema

PGUSER=supabase_admin psql -d postgres -c "
  INSERT INTO realtime.channels (topic, broadcast_storage_enabled_at) VALUES ('news', now());
  CREATE POLICY \"allow_news\" ON realtime.messages_opt3 AS PERMISSIVE FOR INSERT TO bench_writer3 WITH CHECK (extension = 'broadcast' AND topic = 'news');
" >/dev/null
bench_seed_channels 999 1
bench_create_policies 1 999 >/dev/null

echo
{
  echo "## 1. Time to Insert Messages"
  echo
  echo "Scenario: Fixed 1,000 configs already exist, inserting 1 message into a table that already holds M messages."
  echo
  echo "| Messages (M) | Option 1 insert | Option 3 insert | % |"
  echo "|---|---|---|---|"

  prev=0
  for m in "${SCALES[@]}"; do
    bench_seed_messages realtime.messages_opt1 $((m - prev)) news
    bench_seed_messages realtime.messages_opt3 $((m - prev)) news
    prev=$m
    t1=$(bench_pgbench_latency bench_writer1 scenario_1_opt1.sql)
    t3=$(bench_pgbench_latency bench_writer3 scenario_1_opt3.sql)
    pct=$(bench_pct "$t1" "$t3")
    printf "| %s | %s ms | %s ms | %s |\n" "$m" "$t1" "$t3" "$pct"
  done
} | bench_print_table
