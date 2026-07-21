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
TIMEOUT_SECS="${TIMEOUT_SECS:-300}"

trap bench_stop EXIT
bench_start
bench_setup_schema

baseline_channels=$(bench_relation_size realtime.channels)
baseline_policies=$(bench_relation_size pg_catalog.pg_policy)

echo
{
  echo "## 7. Storage size per config"
  echo
  echo "Scenario: N configs exist, measuring on-disk size of the storage mechanism itself."
  echo
  echo "| N | Option 1 (bytes/config) | Option 3 (bytes/config) | % |"
  echo "|---|---|---|---|"

  channels_n=0
  policies_n=0
  policies_capped=false

  for n in "${SCALES[@]}"; do
    echo "-> N=$n" >&2
    bench_seed_channels $((n - channels_n)) $((channels_n + 1))
    channels_n=$n
    channels_bytes=$(bench_relation_size realtime.channels)
    b1=$(awk -v a="$channels_bytes" -v base="$baseline_channels" -v n="$n" 'BEGIN { printf "%.1f", (a - base) / n }')

    if [ "$policies_capped" = false ]; then
      diff=$((n - policies_n))
      if bench_create_policies $((policies_n + 1)) $((policies_n + diff)) "$TIMEOUT_SECS" >/dev/null; then
        policies_n=$n
      else
        policies_capped=true
      fi
    fi

    if [ "$policies_capped" = false ]; then
      policies_bytes=$(bench_relation_size pg_catalog.pg_policy)
      b3=$(awk -v a="$policies_bytes" -v base="$baseline_policies" -v n="$n" 'BEGIN { printf "%.1f", (a - base) / n }')
      pct=$(bench_pct "$b1" "$b3")
      printf "| %s | %s | %s | %s |\n" "$n" "$b1" "$b3" "$pct"
    else
      printf "| %s | %s | timed out (>%ss, killed) | - |\n" "$n" "$b1" "$TIMEOUT_SECS"
    fi
  done
} | bench_print_table
