#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

if [ "$#" -gt 0 ]; then
  SCALES=("$@")
else
  SCALES=(${SCALES:-1 1000 10000 100000 1000000})
fi
bench_print_args "${SCALES[@]}"
TIMEOUT_SECS="${TIMEOUT_SECS:-300}"

trap bench_stop EXIT
bench_start
bench_setup_schema

PGUSER=supabase_admin psql -d postgres -c "
  INSERT INTO realtime.channels (topic, broadcast_storage_enabled_at) VALUES ('news', now());
  CREATE POLICY \"allow_news\" ON realtime.messages_opt3 AS PERMISSIVE FOR INSERT TO bench_writer3 WITH CHECK (extension = 'broadcast' AND topic = 'news');
" >/dev/null

echo
{
  echo "## 4. Check if topic has storage enabled"
  echo
  echo "Scenario: N configs exist, checking whether topic \`news\` is enabled."
  echo
  echo "| Existing configs (N) | Option 1 check | Option 3 check | % |"
  echo "|---|---|---|---|"

  channels_n=1
  policies_n=1
  policies_capped=false

  for n in "${SCALES[@]}"; do
    echo "-> N=$n" >&2
    diff=$((n - channels_n))
    if [ "$diff" -gt 0 ]; then
      bench_seed_channels "$diff" "$channels_n"
    fi
    channels_n=$n

    t1=$(bench_pgbench_latency bench_writer1 scenario_4_opt1.sql)

    if [ "$policies_capped" = false ]; then
      diff=$((n - policies_n))
      if [ "$diff" -gt 0 ]; then
        if bench_create_policies "$policies_n" $((policies_n + diff - 1)) "$TIMEOUT_SECS" >/dev/null; then
          policies_n=$n
        else
          policies_capped=true
        fi
      fi
    fi

    if [ "$policies_capped" = false ]; then
      t3=$(bench_pgbench_latency bench_writer3 scenario_4_opt3.sql)
      pct=$(bench_pct "$t1" "$t3")
      printf "| %s | %s ms | %s ms | %s |\n" "$n" "$t1" "$t3" "$pct"
    else
      printf "| %s | %s ms | timed out (>%ss, killed) | - |\n" "$n" "$t1" "$TIMEOUT_SECS"
    fi
  done
} | bench_print_table
