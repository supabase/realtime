# Developing Supabase Realtime

## Table of contents

- [Client](#client)
  - [Client libraries](#client-libraries)
- [Server](#server)
  - [Architecture](#architecture)
  - [Server Setup](#server-setup)
  - [Devcontainer](#devcontainer)
  - [Tenants](#tenants)
  - [WebSocket](#websocket)
    - [WebSocket URL](#websocket-url)
    - [WebSocket Connection Authorization](#websocket-connection-authorization)
  - [Dependency cooldown](#dependency-cooldown)
  - [Telemetry events](#telemetry-events)

## Client

### Client libraries

| Language     | Source                                                                                                              | Package                                                                      |
| ------------ | ------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| JavaScript   | [supabase-js/realtime-js](https://github.com/supabase/supabase-js/tree/master/packages/core/realtime-js)            | [@supabase/realtime-js](https://www.npmjs.com/package/@supabase/realtime-js) |
| Flutter/Dart | [supabase-flutter/realtime_client](https://github.com/supabase/supabase-flutter/tree/main/packages/realtime_client) | [realtime_client](https://pub.dev/packages/realtime_client)                  |
| Python       | [supabase-py/realtime](https://github.com/supabase/supabase-py/tree/main/src/realtime)                              | [realtime](https://pypi.org/project/realtime)                                |
| Swift        | [supabase-swift/Realtime](https://github.com/supabase/supabase-swift/tree/main/Sources/Realtime)                    | [supabase-swift](https://swiftpackageindex.com/supabase/supabase-swift)      |

## Server

### Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for an overview of the cluster layout, how a
tenant gets placed on a node, how broadcasts are routed, and how Postgres Changes
subscriptions work.

### Server Setup

Pre-requisites:

- [mise](https://mise.jdx.dev) installed and [activated](https://mise.jdx.dev/cli/activate.html) so it can load env vars in your shell.

Optional but recommended:

- [Docker](https://www.docker.com/get-started)
- [Docker Compose](https://docs.docker.com/compose/install) 2.20.0 or later

To run the server locally, start the Postgres databases based on [supabase/postgres](https://github.com/supabase/postgres) that contains all plugins and config required by Realtime:

```bash
mise run db-start
```

With the database running, setup deps and start the server:

```bash
mix setup
mise run dev
```

To start another node in the local cluster (optional):

```bash
mise run dev-orange
```

Once the server is up, open [http://localhost:4000/status](http://localhost:4000/status) to check the services are running.

> **Note**
> To run the whole stack in containers instead of installing Elixir locally:

```bash
mise run realtime-start
```

Useful cleanup commands:

```bash
mise run db-rm
mise run realtime-rm
```

To see all available tasks:

```bash
mise task ls
```

### Devcontainer

If you use VS Code (or another [Dev Containers](https://containers.dev)-compatible editor), `.devcontainer/` gives you a ready-to-use environment without installing mise, Elixir, or Erlang on your host.

The image installs the exact toolchain as discussed above and all commands should work similarly.

To use it, open the repo in VS Code and run **Dev Containers: Reopen in Container**.
Once the container has built and `postCreateCommand` finishes, follow the same steps as above: `mise run db-start`, `mix setup`, `mise run dev`.

> **Note**
> It uses `--network=host`, which requires a container runtime that supports it. This works natively on Linux and on OrbStack; on Docker Desktop for Mac you need to enable the host networking beta feature first.

### Tenants

A tenant has already been added on your behalf. You can confirm this by checking the `_realtime.tenants` and `_realtime.extensions` tables inside the database.

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
            "db_host": "host.docker.internal",
            "db_user": "postgres",
            "db_password": "postgres",
            "db_port": "5432",
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

The WebSocket URL must contain the subdomain, `external_id` of the tenant on the `_realtime.tenants` table, and the token must be signed with the `jwt_secret` that was inserted along with the tenant.

If you're using the default tenant, the URL is `ws://realtime-dev.localhost:4000/socket` (make sure the port is correct for your development environment), and you can use `eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJleHAiOjE3MDMwMjgwODcsInJvbGUiOiJwb3N0Z3JlcyJ9.tz_XJ89gd6bN8MBpCl7afvPrZiBH6RB65iA1FadPT3Y` for the token. The token must have `exp` and `role` (database role) keys.

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
