#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

trap bench_stop EXIT
bench_start
bench_setup_schema

PGUSER=supabase_admin psql -d postgres -c "
  INSERT INTO realtime.channels (topic, broadcast_storage_enabled_at) VALUES ('other', now());
  CREATE POLICY \"allow_news\" ON realtime.messages_opt3 AS PERMISSIVE FOR INSERT TO bench_writer3 WITH CHECK (extension = 'broadcast' AND topic = 'news');
" >/dev/null

(
  psql -h "$PGHOST" -p "$PGPORT" -U supabase_admin -d postgres <<'SQL'
BEGIN;
UPDATE realtime.channels SET broadcast_storage_enabled_at = NULL, updated_at = now() WHERE topic = 'other';
SELECT pg_sleep(3);
COMMIT;
SQL
) &
sleep 1
t1_start=$(date +%s%N)
PGUSER=bench_writer1 psql -d postgres -c "
  INSERT INTO realtime.messages_opt1 (topic, extension, payload, event, private) VALUES ('news', 'broadcast', '{\"msg\":\"bench\"}', 'event', true);
" >/dev/null
t1_end=$(date +%s%N)
wait
t1_ms=$(awk -v a="$t1_start" -v b="$t1_end" 'BEGIN { printf "%.1f", (b - a) / 1000000 }')

(
  psql -h "$PGHOST" -p "$PGPORT" -U supabase_admin -d postgres <<'SQL'
BEGIN;
CREATE POLICY "allow_other" ON realtime.messages_opt3 AS PERMISSIVE FOR INSERT TO bench_writer3 WITH CHECK (extension = 'broadcast' AND topic = 'other');
SELECT pg_sleep(3);
COMMIT;
SQL
) &
sleep 1
t3_start=$(date +%s%N)
PGUSER=bench_writer3 psql -d postgres -c "
  INSERT INTO realtime.messages_opt3 (topic, extension, payload, event, private) VALUES ('news', 'broadcast', '{\"msg\":\"bench\"}', 'event', true);
" >/dev/null
t3_end=$(date +%s%N)
wait
t3_ms=$(awk -v a="$t3_start" -v b="$t3_end" 'BEGIN { printf "%.1f", (b - a) / 1000000 }')

echo
{
  echo "## 8. Does enabling/disabling a config block other topics' inserts?"
  echo
  echo "Scenario: topic \`other\`'s config is being enabled/disabled while topic \`news\` (untouched) concurrently inserts a message."
  echo
  echo "| | Option 1 | Option 3 |"
  echo "|---|---|---|"
  echo "| Lock taken | RowExclusiveLock on realtime.channels | AccessExclusiveLock on realtime.messages_opt3 |"
  printf "| Concurrent insert for unrelated topic \`news\` took | %s ms | %s ms |\n" "$t1_ms" "$t3_ms"
} | bench_print_table
