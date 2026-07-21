#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

if [ "$#" -gt 0 ]; then
  CHECKPOINTS=("$@")
else
  CHECKPOINTS=(1 1000 10000 100000 1000000)
fi
bench_print_args "${CHECKPOINTS[@]}"
TIMEOUT_SECS="${TIMEOUT_SECS:-300}"

RANGES=()
prev=0
for checkpoint in "${CHECKPOINTS[@]}"; do
  RANGES+=("$prev $checkpoint")
  prev=$checkpoint
done

trap bench_stop EXIT
bench_start
bench_setup_schema

echo
{
  echo "## 2. Time to Insert Config"
  echo
  echo "Scenario: N configs already exist, bulk-adding k more configs (N+1..N+k)."
  echo
  echo "| Configs (N) | Option 1 (bulk insert N+1..N+k) | Option 3 (bulk \`CREATE POLICY\` N+1..N+k) | % |"
  echo "|---|---|---|---|"

  policies_capped=false

  for range in "${RANGES[@]}"; do
    read -r start end <<<"$range"
    echo "-> $start -> $end" >&2

    t1=$(bench_time_sql "INSERT INTO realtime.channels (topic, broadcast_storage_enabled_at) SELECT 'topic:' || i, now() FROM generate_series($((start + 1)), $end) i;")

    if [ "$policies_capped" = false ] && t3=$(bench_create_policies $((start + 1)) "$end" "$TIMEOUT_SECS") && [ -n "$t3" ]; then
      pct=$(bench_pct "$t1" "$t3")
      printf "| %s -> %s | %s ms | %s ms | %s |\n" "$start" "$end" "$t1" "$t3" "$pct"
    else
      policies_capped=true
      printf "| %s -> %s | %s ms | timed out (>%ss, killed) | - |\n" "$start" "$end" "$t1" "$TIMEOUT_SECS"
    fi
  done
} | bench_print_table
