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

echo
{
  echo "## 3. Disable one config, at scale"
  echo
  echo "Scenario: N configs already exist and are enabled, disabling 1 of them."
  echo
  echo "| Existing configs (N) | Option 1 disable | Option 3 disable | % |"
  echo "|---|---|---|---|"

  channels_n=0
  policies_n=0
  policies_capped=false

  for n in "${SCALES[@]}"; do
    echo "-> N=$n" >&2
    PGUSER=supabase_admin psql -d postgres -c "
      INSERT INTO realtime.channels (topic, broadcast_storage_enabled_at) VALUES ('news', now())
      ON CONFLICT (topic) DO UPDATE SET broadcast_storage_enabled_at = now();
    " >/dev/null
    diff=$(((n - 1) - channels_n))
    if [ "$diff" -gt 0 ]; then
      bench_seed_channels "$diff" $((channels_n + 1))
    fi
    channels_n=$((n - 1))

    t1=$(bench_time_sql "UPDATE realtime.channels SET broadcast_storage_enabled_at = NULL, updated_at = now() WHERE topic = 'news';")

    if [ "$policies_capped" = false ]; then
      PGUSER=supabase_admin psql -d postgres -c "
        DO \$\$ BEGIN
          IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname='realtime' AND tablename='messages_opt3' AND policyname='allow_news') THEN
            CREATE POLICY \"allow_news\" ON realtime.messages_opt3 AS PERMISSIVE FOR INSERT TO bench_writer3 WITH CHECK (extension = 'broadcast' AND topic = 'news');
          END IF;
        END \$\$;
      " >/dev/null

      diff=$(((n - 1) - policies_n))
      if [ "$diff" -gt 0 ]; then
        if bench_create_policies $((policies_n + 1)) $((policies_n + diff)) "$TIMEOUT_SECS" >/dev/null; then
          policies_n=$((n - 1))
        else
          policies_capped=true
        fi
      else
        policies_n=$((n - 1))
      fi
    fi

    if [ "$policies_capped" = false ]; then
      t3=$(bench_time_sql "DROP POLICY \"allow_news\" ON realtime.messages_opt3;")
      pct=$(bench_pct "$t1" "$t3")
      printf "| %s | %s ms | %s ms | %s |\n" "$n" "$t1" "$t3" "$pct"
    else
      printf "| %s | %s ms | timed out (>%ss, killed) | - |\n" "$n" "$t1" "$TIMEOUT_SECS"
    fi
  done
} | bench_print_table
