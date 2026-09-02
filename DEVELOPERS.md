# Developing Supabase Realtime

## Table of contents

- [Client](#client)
  - [Client libraries](#client-libraries)
- [Server](#server)
  - [Architecture](#architecture)
  - [Server setup](#server-setup)
  - [Tenants](#tenants)
  - [Devcontainer](#devcontainer)
  - [WebSocket](#websocket)
    - [WebSocket URL](#websocket-url)
    - [WebSocket Connection Authorization](#websocket-connection-authorization)
  - [Dependency cooldown](#dependency-cooldown)
  - [Telemetry events](#telemetry-events)

## Client

### Client libraries

| Language     | Source                                                                                                    | Package                                                                                         |
| ------------ | --------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| JavaScript   | [supabase-js](https://github.com/supabase/supabase-js/tree/master/packages/core/realtime-js)              | [@supabase/realtime-js](https://www.npmjs.com/package/@supabase/realtime-js)                    |
| Flutter/Dart | [supabase-flutter](https://github.com/supabase/supabase-flutter/tree/main/packages/supabase_realtime)     | [supabase_realtime](https://pub.dev/packages/supabase_realtime)                                 |
| Python       | [supabase-py](https://github.com/supabase/supabase-py/tree/main/src/realtime)                             | [realtime](https://pypi.org/project/realtime)                                                   |
| Swift        | [supabase-swift](https://github.com/supabase/supabase-swift/tree/main/Sources/Realtime)                   | [supabase-swift](https://swiftpackageindex.com/supabase/supabase-swift)                         |
| C#           | [supabase-csharp](https://github.com/supabase-community/supabase-csharp/tree/master/packages/Realtime)    | [Supabase.Realtime](https://www.nuget.org/packages/Supabase.Realtime)                           |
| Kotlin       | [supabase-kt](https://github.com/supabase-community/supabase-kt/tree/master/Realtime)                     | [realtime-kt](https://central.sonatype.com/artifact/io.github.jan-tennert.supabase/realtime-kt) |

See the [SDK capability matrix](https://supabase.github.io/sdk/#area-realtime).

## Server

### Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for an overview of the cluster layout, how a
tenant gets placed on a node, how broadcasts are routed, and how Postgres Changes
subscriptions work.

### Server setup

Realtime is multi-tenant. One Postgres holds the tenant registry, and every tenant has its own Postgres holding the data its
clients subscribe to. Locally both are containers.

Requirements:

- [mise](https://mise.jdx.dev), installed and [activated](https://mise.jdx.dev/cli/activate.html) so it loads env vars in your shell
- [Docker](https://www.docker.com/get-started) with [Docker Compose](https://docs.docker.com/compose/install) 2.20.0 or later

First time, in this order:

```bash
mix setup           # Elixir and asset deps
mise run db-start   # realtime database on 5432, migrations, and the realtime-dev tenant with its database on 5433
mise run dev        # server on http://localhost:4000, default tenant at ws://realtime-dev.localhost:4000/socket
```

Data survives restarts: `mise run db-stop` then `db-start` keeps it, and so does restarting the server. Only `db-rm`
discards it. Both act on a single tenant's database; the realtime database is shared with every other checkout, so no
task stops it.

### Tenants

With the realtime database running, you can add more tenants to isolate and simulate new environments.
Useful for code reviewing and simultaneous work on worktrees.

```bash
TENANT=review mise run db-start  # tenant named review, database on a port docker picks
TENANT=review mise run db-rm     # removes its database
```

You don't need to set `TENANT`, but you can. It defaults to the checkout's directory name, so a worktree in
`realtime.review` is the `realtime-review` tenant already, and a plain `realtime` checkout is `realtime-dev`.
Re-running `db-start` leaves an existing tenant's data and publication alone.

`TENANT` isolates the test suite too, so `mix test` runs on its own database and tenant containers, next to that
tenant's dev stack and clear of every other run.

> **Note**
> Supabase runs Realtime in production with a separate database that keeps track of all tenants. For local development, the compose setup creates the `_realtime` schema for you.

You can add your own by making a `POST` request to the server. You must change both `name` and `external_id` while you may update other values as you see fit:

```bash
  curl -X POST \
  -H 'Content-Type: application/json' \
  -H 'Authorization: Bearer eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.eyJpc3MiOiIiLCJpYXQiOjE2NzEyMzc4NzMsImV4cCI6MTcwMjc3Mzk5MywiYXVkIjoiIiwic3ViIjoiIn0._ARixa2KFUVsKBf3UGR90qKLCpGjxhKcXY4akVbmeNQ' \
  -d $'{
    "tenant" : {
      "name": "realtime-dev",
      "external_id": "realtime-dev",
      "jwt_secret": "a1d99c8b-91b6-47b2-8f3c-aa7d9a9ad20f",
      "extensions": [
        {
          "type": "postgres_cdc_rls",
          "settings": {
            "db_name": "postgres",
            "db_host": "127.0.0.1",
            "db_user": "postgres",
            "db_password": "postgres",
            "db_port": "5433",
            "region": "us-west-1",
            "poll_interval_ms": 100,
            "poll_max_record_bytes": 1048576,
            "ssl_enforced": false
          }
        }
      ]
    }
  }' \
  http://localhost:4000/api/tenants
```

> **Note**
> The `Authorization` token is signed with the secret set by `API_JWT_SECRET` in the local compose environment.

If you want to listen to Postgres changes, you can create a table and then add the table to the `supabase_realtime` publication:

```sql
create table test (
  id serial primary key
);

alter publication supabase_realtime add table test;
```

You can start playing around with Broadcast, Presence, and Postgres Changes features either with the client libs (e.g. `@supabase/realtime-js`), or use the built in Realtime Inspector on localhost, `http://localhost:4000/inspector/new` (make sure the port is correct for your development environment).

The WebSocket URL must contain the subdomain, `external_id` of the tenant on the `tenants` table, and the token must be signed with the `jwt_secret` that was inserted along with the tenant.

If you're using the default tenant, the URL is `ws://realtime-dev.localhost:4000/socket` (make sure the port is correct for your development environment), and you can use `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDMwMjgwODcsInJvbGUiOiJwb3N0Z3JlcyJ9.tz_XJ89gd6bN8MBpCl7afvPrZiBH6RB65iA1FadPT3Y` for the token. The token must have `exp` and `role` (database role) keys.

### Devcontainer

If you use VS Code (or another [Dev Containers](https://containers.dev)-compatible editor), `.devcontainer/` gives you a ready-to-use environment without installing mise, Elixir, or Erlang on your host.

The image installs the exact toolchain as discussed above and all commands should work similarly.

To use it, open the repo in VS Code and run **Dev Containers: Reopen in Container**.
Once the container has built and `postCreateCommand` finishes, follow the same steps as above: `mix setup`, `mise run db-start`, `mise run dev`.

> **Note**
> It uses `--network=host`, which requires a container runtime that supports it. This works natively on Linux and on OrbStack; on Docker Desktop for Mac you need to turn on the host networking beta feature first.

### WebSocket

#### WebSocket URL

The WebSocket URL is in the following format for local development: `ws://[external_id].localhost:4000/socket/websocket`

If you're using Supabase's hosted Realtime in production the URL is `wss://[project-ref].supabase.co/realtime/v1/websocket?apikey=[anon-token]&log_level=info&vsn=1.0.0"`

#### WebSocket Connection Authorization

WebSocket connections are authorized via symmetric JWT verification. Only supports JWTs signed with the following algorithms:

- HS256
- HS384
- HS512

Verify JWT claims by setting JWT_CLAIM_VALIDATORS:

> e.g. {'iss': 'Issuer', 'nbf': 1610078130}
>
> Then JWT's "iss" value must equal "Issuer" and "nbf" value must equal 1610078130.

**Note:**

> JWT expiration is checked automatically. `exp` and `role` (database role) keys are mandatory.

**Authorizing Client Connection**: You can pass in the JWT by following the instructions under the Realtime client lib. For example, refer to the **Usage** section in the [@supabase/realtime-js](https://github.com/supabase/realtime-js) client library.

### Dependency cooldown

[mix.exs](mix.exs) sets a [cooldown for dependencies](https://hex.pm/docs/dependency-policies).
This creates a window to guard against broken or malicious releases.

If you need a freshly published release (e.g. to pick up a fix), you can bypass the cooldown:

```bash
HEX_COOLDOWN=0d mix deps.update your_dependency
```

You can also exempt specific dependencies from this cooldown (f.ex. if you trust them especially):

```elixir
hex: [
  cooldown: "7d",
  cooldown_exclude_repos: ["repo"]
]
```

### Telemetry events

Realtime emits events through `:telemetry`. Event names follow a few rules so they map cleanly onto metrics and stay consistent:

- Prefix every event with `:realtime` and group preferably by concern, otherwise by module. Tenant migrations use `[:realtime, :tenants, :migrations, ...]`, channels use `[:realtime, :channel, ...]`, and the Postgres CDC workers use `[:realtime, :replication, :poller, ...]` and `[:realtime, :subscriptions, :manager, ...]`.
- Give anything with a lifetime a span: `:start`, then `:stop` or `:exception`. Put the duration in measurements and the cause in metadata. Tenant migrations emit `[:realtime, :tenants, :migrations, :start | :stop | :exception]`, and the replication poller does the same for its run and for its `:query` and `:prepare` operations.
- When outcomes share a cause, emit one event and tell them apart with a `reason` in metadata instead of adding an event name per outcome. For example, skipped Postgres changes use `[:realtime, :replication, :poller, :changes, :skip]` with `reason: :rate_limited`.
- Put `tenant` in metadata for per-tenant events; connections, authorization checks, and migrations all do. Extra context such as `reason` or `db_pid` also goes in metadata and stays out of metrics unless a metric opts into it as a tag.
- A metric name is the event path joined with `_`, so pick segments that read well as one: `[:realtime, :tenants, :payload, :size]` becomes `realtime_tenants_payload_size`.

The metrics built on these events are listed in [OBSERVABILITY_METRICS.md](./OBSERVABILITY_METRICS.md).
