# Realtime E2E tests

| Option | Env var | Description |
|---|---|---|
| `--project` | | Supabase project ref (not needed for `--env local`) |
| `--publishable-key` | `SUPABASE_ANON_KEY` | Project anon/public key |
| `--secret-key` | `SUPABASE_SERVICE_ROLE_KEY` | Project service role key |
| `--db-password` | `SUPABASE_DB_PASSWORD` | Database password (required for staging/prod) |
| `--env` | | `local` \| `staging` \| `prod` (default: `prod`) |
| `--domain` | | Email domain for the test user (default: `example.com`) |
| `--port` | | Override URL port (useful for local) |
| `--test` | | Comma-separated list of test categories to run (runs all if omitted) |
| `--json` | | Output results as JSON to stdout (all other output goes to stderr) |
| `--url` | | Override project URL (e.g. `http://127.0.0.1:54321`) |
| `--db-url` | | Override database URL (e.g. `postgresql://postgres:postgres@127.0.0.1:54322/postgres`) |
| `--otel` | `OTEL_EXPORTER_OTLP_ENDPOINT` | OTLP HTTP endpoint for tracing (e.g. `http://localhost:4318`) |
| | `OTEL_API_TOKEN` | Bearer token for authenticated OTLP endpoints |

Sensitive credentials (`--secret-key`, `SUPABASE_DB_PASSWORD`) should be set as environment variables to avoid them appearing in shell history.

A random test user is created at the start of each run and deleted automatically when it finishes.

## Test categories

Pass any combination to `--test` as a comma-separated list. Use `functional` to run all non-load suites, or `load` to run all load suites.

| Category | Suites | Tests |
|---|---|---|
| `connection` | connection | First connect latency; broadcast message throughput |
| `load` | load-postgres-changes | Postgres system message latency; INSERT / UPDATE / DELETE throughput via postgres changes |
| | load-presence | Presence join throughput |
| | load-broadcast-from-db | Broadcast-from-database throughput |
| | load-broadcast | Self-broadcast throughput; REST broadcast API throughput |
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
SUPABASE_SERVICE_ROLE_KEY=<service-role-key> \
  ./realtime-check --env local --publishable-key <anon-key>
```

### Local project with tracing

```bash
supabase start
docker compose up -d  # starts Jaeger at http://localhost:16686
SUPABASE_SERVICE_ROLE_KEY=<service-role-key> \
  ./realtime-check --env local --publishable-key <anon-key> --otel http://localhost:4318
```

For authenticated OTLP endpoints, set `OTEL_API_TOKEN` and it will be sent as a `Bearer` token:

```bash
SUPABASE_SERVICE_ROLE_KEY=<service-role-key> \
OTEL_API_TOKEN=<token> \
  ./realtime-check --env local --publishable-key <anon-key> --otel https://otlp.example.com
```

### Remote project

```bash
SUPABASE_SERVICE_ROLE_KEY=<service-role-key> \
SUPABASE_DB_PASSWORD=<password> \
  ./realtime-check --project <project-ref> --publishable-key <anon-key>
```

## Using Bun

Requires [Bun](https://bun.sh).

### Run without building

```bash
bun install
SUPABASE_SERVICE_ROLE_KEY=<key> SUPABASE_DB_PASSWORD=<pw> \
  bun run check -- --project <ref> --publishable-key <key>
```

### Build the binary

```bash
bun install
bun run build
SUPABASE_SERVICE_ROLE_KEY=<key> SUPABASE_DB_PASSWORD=<pw> \
  ./realtime-check --project <ref> --publishable-key <key>
```

## Using Nix

Requires flakes support. Add this once to `/etc/nix/nix.conf`:

```
experimental-features = nix-command flakes
```

### Build and run

```bash
bun run nix
SUPABASE_SERVICE_ROLE_KEY=<key> SUPABASE_DB_PASSWORD=<pw> \
  ./result/bin/realtime-check --project <ref> --publishable-key <key>
```

`bun run nix` calls `nix-build.sh`, which automatically updates the `outputHash` in `flake.nix` when `package.json` or `bun.lock` change — no manual hash update needed.

---

## Deno tests (legacy)

See [legacy/README.md](./legacy/README.md).
