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

Sensitive credentials (`--secret-key`, `SUPABASE_DB_PASSWORD`) should be set as environment variables to avoid them appearing in shell history.

A random test user is created at the start of each run and deleted automatically when it finishes.

## Test categories

Pass any combination to `--test` as a comma-separated list:

| Category | Description |
|---|---|
| `connection` | WebSocket connect latency and broadcast throughput |
| `load` | Postgres changes and presence throughput (INSERT / UPDATE / DELETE) |
| `broadcast` | Self-broadcast and REST broadcast API |
| `presence` | Presence join on public and private channels |
| `authorization` | Private channel allow/deny checks |
| `postgres-changes` | Filtered INSERT, UPDATE, DELETE events and concurrent changes |
| `broadcast-changes` | Database-triggered broadcast INSERT, UPDATE, DELETE events |

```bash
# Run only connection and broadcast tests
./realtime-check --env local --publishable-key <key> --secret-key <key> --test connection,broadcast
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

```bash
supabase start
SUPABASE_SERVICE_ROLE_KEY=<service-role-key> \
  ./realtime-check --env local --publishable-key <anon-key>
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

> **Note:** The nix build locks the dependency hash in `flake.nix`. If you update `package.json` or `bun.lock`, run `nix build` once — it will fail with the new hash in the error output — then update `outputHash` in `flake.nix` accordingly.

---

## Deno tests (legacy)

See [legacy/README.md](./legacy/README.md).
