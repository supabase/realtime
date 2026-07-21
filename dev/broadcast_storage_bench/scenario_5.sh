#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

N="${1:-1000}"
bench_print_args "$N"

trap bench_stop EXIT
bench_start
bench_setup_schema

bench_seed_channels "$N" 1
bench_create_policies 1 "$N" >/dev/null

t1=$(bench_time_sql "SELECT topic FROM realtime.channels WHERE broadcast_storage_enabled_at IS NOT NULL;")
t3=$(bench_time_sql "SELECT policyname, with_check FROM pg_policies WHERE schemaname = 'realtime' AND tablename = 'messages_opt3';")

echo
{
  echo "## 5. Check which topics have storage enabled"
  echo
  echo "Scenario: $N configs exist, listing every enabled topic."
  echo
  echo "| Existing configs (N) | Option 1 list | Option 3 list | % |"
  echo "|---|---|---|---|"
  printf "| %s | %s ms | %s ms | %s |\n" "$N" "$t1" "$t3" "$(bench_pct "$t1" "$t3")"
} | bench_print_table
