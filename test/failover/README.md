# Failover harness

Shows what Realtime delivers across a database primary failover. It signs in a test user, subscribes to three streams, writes a numbered row every 500 ms, waits for you to trigger a failover, and reports per stream what arrived.

| Stream | Source |
|---|---|
| `postgres_changes` | inserts into `pg_changes` (filtered on a run id) |
| `broadcast_from_db` | trigger on `broadcast_changes` calling `realtime.broadcast_changes` (private channel) |
| `broadcast_control` | `channel.send` (no database involved; the control) |
| late join | a new Postgres Changes channel joined after the trigger (`--late-join-after-s`, default 2, 0 disables) |

For each stream the report gives acknowledged writes and write errors, events received, duplicates, missing events, the longest silent gap, the time to the first event after the trigger, and whether the last 10 acknowledged writes all arrived. It also prints every channel status and system message with timestamps. With `--db-url` it prints `pg_is_in_recovery()`, `pg_postmaster_start_time()`, the WAL position and the replication slots before and after.

## Requirements

- [Bun](https://bun.sh)
- A hosted project whose database has a standby to fail over to, with the Realtime tenant registered, and its publishable and secret keys
- The fixtures from the e2e suite: run `realtime-check --test functional` (see [`../e2e`](../e2e)) against the project once, which creates `pg_changes`, `broadcast_changes`, their policies and the broadcast trigger
- Someone who can trigger a failover on that project

## Run

```bash
bun install
bun run check -- --url https://<ref>.<domain> --publishable-key <key> --secret-key <key> \
  --db-url "postgresql://postgres:<pw>@<db-host>:5432/postgres?sslmode=require&sslnegotiation=direct" \
  --warmup-s 20 --after-s 120 --json result.json
```

When the banner prints, trigger the failover and press Enter at that moment. Or pass `--trigger-cmd '<shell command>'` and the harness runs it itself, which gives an exact trigger time. The report goes to stderr, and `--json` also writes it to a file.

Pass the full `--db-url`: where the database host expects direct TLS negotiation, `sslnegotiation=direct` is required, and a password-only URL hangs.

| Flag | Default | Meaning |
|---|---|---|
| `--url` | required | the project URL |
| `--interval-ms` | 500 | delay between writes |
| `--warmup-s` / `--after-s` | 20 / 90 | seconds of traffic before the trigger / after it |
| `--late-join-after-s` | 2 | seconds after the trigger to join a new Postgres Changes channel (0 disables) |
| `--write-timeout-ms` | 10000 | per-write timeout |
| `--max-gap-ms` | 60000 | a stream silent for longer than this fails |
| `--json` | | write the full report to a file |

## Run it locally

`local.sh` runs the whole thing on your machine, with no hosted project or cluster access. It reuses the e2e stack in `../e2e/stack` (Realtime built from this checkout, GoTrue, PostgREST and a gateway) with the tenant database on the Multigres cluster image from `.github/db-images.json`. Three cells run in the one `tenant_db` container, so the shard keeps a quorum after losing a node. Requires Docker and Bun.

```bash
test/failover/local.sh up                      # build and start the stack, create the fixtures (a few minutes)
test/failover/local.sh run planned [flags]     # graceful switchover while the harness runs
test/failover/local.sh run unplanned [flags]   # kill the primary's postgres and pooler
test/failover/local.sh status                  # which pooler is the primary
test/failover/local.sh down                    # remove the stack and its volumes
```

Flags after the scenario go to the harness (`--warmup-s`, `--after-s`, `--late-join-after-s`, `--json`, and so on). The harness runs the trigger itself, so the trigger time is exact.

- The gateway failover buffer is on, as on hosted projects. It is off by default in the cluster image: `MT_BUFFER_ENABLED=false test/failover/local.sh up` starts without it, which shows how clients behave when the gateway returns errors during a switchover instead of holding queries.
- An unplanned run leaves the killed cell down; run `down` and `up` before another one. A planned run can be repeated, but the gateway buffers one failover a minute, so leave a minute between runs.
- Realtime logs are `docker logs failover-multigres-realtime-1`. Everything runs in one container, so network and pod-termination timing differ from a hosted project.

## Reading the report

- `broadcast_control` should be clean. A gap there means the whole connection was affected, not only the replication stream.
- A stream passes if `recovered_last_10` is true and its longest gap is within `--max-gap-ms`. Missing events do not fail a run on their own.
- `recovered_last_10: false` means the stream never resumed. Check the channel events at the end of the report and the tenant logs.
- `write_errors` with no gap means writes were rejected during the window but Realtime was fine.
- A different `postmaster_start` in `after` than in `before` shows another Postgres answered, which means the failover happened.

## Limits

- One tenant at 2 writes a second. Failovers affecting many tenants at once are not covered.
- Writes go through PostgREST as the authenticated user, not directly to Postgres.
- The harness cannot tell whether a gap comes from Realtime or from the database coming back; compare it with the tenant and database logs.
- Cleanup: the harness deletes its test user and its `pg_changes` rows. The tables and `broadcast_changes` rows are left in place.
