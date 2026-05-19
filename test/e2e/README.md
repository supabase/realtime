# Realtime E2E tests

| Option | Description |
|---|---|
| `--project` | Supabase project ref (not needed for `--env local`) |
| `--publishable-key` | Project anon/public key |
| `--secret-key` | Project service role key |
| `--db-password` | Database password (required for staging/prod) |
| `--env` | `local` \| `staging` \| `prod` (default: `prod`) |
| `--domain` | Email domain for the test user (default: `example.com`) |
| `--port` | Override URL port (useful for local) |
| `--test` | Comma-separated list of test categories to run (runs all if omitted) |
| `--json` | Output results as JSON to stdout (all other output goes to stderr) |
| `--url` | Override project URL (e.g. `http://127.0.0.1:54321`) |
| `--db-url` | Override database URL (e.g. `postgresql://postgres:postgres@127.0.0.1:54322/postgres`) |
| `--otel` | OTLP HTTP endpoint for tracing (e.g. `http://localhost:4318`) |
| `--otel-token` | Bearer token for authenticated OTLP endpoints |

A random test user is created at the start of each run and deleted automatically when it finishes.

## Test categories

Pass any combination to `--test` as a comma-separated list. Use `functional` to run all non-load suites, or `load` to run all load suites.

| Category | Suites | Tests |
|---|---|---|
| `connection` | connection | First connect latency; broadcast message throughput |
| `load` | load-postgres-changes | Postgres system message latency; INSERT / UPDATE / DELETE throughput via postgres changes |
| | load-presence | Presence join throughput |
| | load-broadcast-from-db | Broadcast-from-database throughput |
| | load-broadcast` | Self-broadcast throughput; REST broadcast API throughput |
| | load-broadcast-replay | Broadcast replay throughput on channel join |
| `broadcast` | broadcast extension | Self-broadcast receive; REST broadcast API send-and-receive |
| `presence` | presence extension | Presence join on public channels; presence join on private channels |
| `authorization` | authorization check | Private channel denied without permissions; private channel allowed with permissions |
| `postgres-changes` | postgres changes extension | Filtered INSERT, UPDATE, DELETE events; concurrent INSERT + UPDATE + DELETE |
| `broadcast-changes` | broadcast changes | DB-triggered broadcast for INSERT, UPDATE, DELETE |
| `broadcast-replay` | broadcast replay | Replayed messages delivered on join; `meta.replayed` flag set; messages before `since` not replayed |

```bash
# Run only connection and broadcast tests
./realtime-check --env local --publishable-key <key> --secret-key <key> --test connection,broadcast

# Run all load tests
./realtime-check --env local --publishable-key <key> --secret-key <key> --test load

# Run all functional (non-load) tests
./realtime-check --env local --publishable-key <key> --secret-key <key> --test functional
```

## JSON output

When `--json` is used, only the JSON is written to stdout — all progress and diagnostic output goes to stderr — making it safe to pipe directly to `jq`:

```bash
./realtime-check --json ... | jq '.slis'
./realtime-check --json ... | jq '.suites["broadcast extension"].tests'
./realtime-check --json ... | jq 'select(.passed == false)'
```

## Using the binary

The pre-built binary requires no runtime — just run it directly.

### Local project

A `supabase/config.toml` is included, so `supabase start` works out of the box.

```bash
supabase start
./realtime-check --env local --publishable-key <anon-key> --secret-key <service-role-key>
```

### Local project with tracing

```bash
supabase start
docker compose up -d  # starts Jaeger at http://localhost:16686
./realtime-check --env local --publishable-key <anon-key> --secret-key <service-role-key> --otel http://localhost:4318
```

For authenticated OTLP endpoints:

```bash
./realtime-check --env local --publishable-key <anon-key> --secret-key <service-role-key> \
  --otel https://otlp.example.com --otel-token <token>
```

### Remote project

```bash
./realtime-check --project <project-ref> --publishable-key <anon-key> \
  --secret-key <service-role-key> --db-password <password>
```

## Using Bun

Requires [Bun](https://bun.sh).

### Run without building

```bash
bun install
bun run check -- --project <ref> --publishable-key <key> --secret-key <key> --db-password <pw>
```

### Build the binary

```bash
bun install
bun run build
./realtime-check --project <ref> --publishable-key <key> --secret-key <key> --db-password <pw>
```

## Using Nix

Requires flakes support. Add this once to `/etc/nix/nix.conf`:

```
experimental-features = nix-command flakes
```

### Build and run

```bash
bun run nix
./result/bin/realtime-check --project <ref> --publishable-key <key> --secret-key <key> --db-password <pw>
```

`bun run nix` calls `nix-build.sh`, which automatically updates the `outputHash` in `flake.nix` when `package.json` or `bun.lock` change — no manual hash update needed.

---

## Deno tests (legacy)

See [legacy/README.md](./legacy/README.md).
