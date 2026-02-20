<br />
<p align="center">
  <a href="https://supabase.io">
        <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/supabase/supabase/master/packages/common/assets/images/supabase-logo-wordmark--dark.svg">
      <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/supabase/supabase/master/packages/common/assets/images/supabase-logo-wordmark--light.svg">
      <img alt="Supabase Logo" width="300" src="https://raw.githubusercontent.com/supabase/supabase/master/packages/common/assets/images/logo-preview.jpg">
    </picture>
  </a>

  <h1 align="center">Supabase Realtime</h1>

  <p align="center">
    Send ephemeral messages, track and synchronize shared state, and listen to Postgres changes all over WebSockets.
    <br />
    <a href="https://multiplayer.dev">Multiplayer Demo</a>
    ·
    <a href="https://github.com/supabase/realtime/issues/new?assignees=&labels=enhancement&template=2.Feature_request.md">Request Feature</a>
    ·
    <a href="https://github.com/supabase/realtime/issues/new?assignees=&labels=bug&template=1.Bug_report.md">Report Bug</a>
    <br />
  </p>
</p>

## Status

[![GitHub License](https://img.shields.io/github/license/supabase/realtime)](https://github.com/supabase/realtime/blob/main/LICENSE)
[![Coverage Status](https://coveralls.io/repos/github/supabase/realtime/badge.svg?branch=main)](https://coveralls.io/github/supabase/realtime?branch=main)

| Features         | v1  | v2  | Status |
| ---------------- | --- | --- | ------ |
| Postgres Changes | ✔   | ✔   | GA     |
| Broadcast        |     | ✔   | GA     |
| Presence         |     | ✔   | GA     |

This repository focuses on version 2 but you can still access the previous version's [code](https://github.com/supabase/realtime/tree/v1) and [Docker image](https://hub.docker.com/layers/supabase/realtime/v1.0.0/images/sha256-e2766e0e3b0d03f7e9aa1b238286245697d0892c2f6f192fd2995dca32a4446a). For the latest Docker images go to https://hub.docker.com/r/supabase/realtime.

The codebase is under heavy development and the documentation is constantly evolving. Give it a try and let us know what you think by creating an issue. Watch [releases](https://github.com/supabase/realtime/releases) of this repo to get notified of updates. And give us a star if you like it!

## Overview

### What is this?

This is a server built with Elixir using the [Phoenix Framework](https://www.phoenixframework.org) that enables the following functionality:

- Broadcast: Send ephemeral messages from client to clients with low latency.
- Presence: Track and synchronize shared state between clients.
- Postgres Changes: Listen to Postgres database changes and send them to authorized clients.

For a more detailed overview head over to [Realtime guides](https://supabase.com/docs/guides/realtime).

### Does this server guarantee message delivery?

The server does not guarantee that every message will be delivered to your clients so keep that in mind as you're using Realtime.

## Quick start

You can check out the [Supabase UI Library](https://supabase.com/ui) Realtime components and the [multiplayer.dev](https://multiplayer.dev) demo app source code [here](https://github.com/supabase/multiplayer.dev)

## Client libraries

- [JavaScript](https://github.com/supabase/supabase-js/tree/master/packages/core/realtime-js)
- [Flutter/Dart](https://github.com/supabase/supabase-flutter/tree/main/packages/realtime_client)
- [Python](https://github.com/supabase/supabase-py/tree/main/src/realtime)
- [Swift](https://github.com/supabase/supabase-swift/tree/main/Sources/Realtime)

## Server Setup

To get started, spin up your Postgres database and Realtime server containers defined in `docker-compose.yml`. As an example, you may run `docker-compose -f docker-compose.yml up`.

> **Note**
> Supabase runs Realtime in production with a separate database that keeps track of all tenants. However, a schema, `_realtime`, is created when spinning up containers via `docker-compose.yml` to simplify local development.

A tenant has already been added on your behalf. You can confirm this by checking the `_realtime.tenants` and `_realtime.extensions` tables inside the database.

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
> The `Authorization` token is signed with the secret set by `API_JWT_SECRET` in `docker-compose.yml`.

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

**Environment Variables**

| Variable                                        | Type    | Description                                                                                                                                                                                                                                                                                                                     |
| ----------------------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| PORT                                            | number  | Port which you can connect your client/listeners                                                                                                                                                                                                                                                                                |
| DB_HOST                                         | string  | Database host URL                                                                                                                                                                                                                                                                                                               |
| DB_PORT                                         | number  | Database port                                                                                                                                                                                                                                                                                                                   |
| DB_USER                                         | string  | Database user                                                                                                                                                                                                                                                                                                                   |
| DB_PASSWORD                                     | string  | Database password                                                                                                                                                                                                                                                                                                               |
| DB_NAME                                         | string  | Postgres database name                                                                                                                                                                                                                                                                                                          |
| DB_ENC_KEY                                      | string  | Key used to encrypt sensitive fields in \_realtime.tenants and \_realtime.extensions tables. Recommended: 16 characters.                                                                                                                                                                                                        |
| DB_AFTER_CONNECT_QUERY                          | string  | Query that is run after server connects to database.                                                                                                                                                                                                                                                                            |
| DB_IP_VERSION                                   | string  | Sets the IP Version to be used. Allowed values are "ipv6" and "ipv4". If none are set we will try to infer the correct version                                                                                                                                                                                                  |
| DB_SSL                                          | boolean | Whether or not the connection will be set-up using SSL                                                                                                                                                                                                                                                                          |
| DB_SSL_CA_CERT                                  | string  | Filepath to a CA trust store (e.g.: /etc/cacert.pem). If defined it enables server certificate verification                                                                                                                                                                                                                     |
| API_JWT_SECRET                                  | string  | Secret that is used to sign tokens used to manage tenants and their extensions via HTTP requests.                                                                                                                                                                                                                               |
| SECRET_KEY_BASE                                 | string  | Secret used by the server to sign cookies. Recommended: 64 characters.                                                                                                                                                                                                                                                          |
| ERL_AFLAGS                                      | string  | Set to either "-proto_dist inet_tcp" or "-proto_dist inet6_tcp" depending on whether or not your network uses IPv4 or IPv6, respectively.                                                                                                                                                                                       |
| APP_NAME                                        | string  | A name of the server.                                                                                                                                                                                                                                                                                                           |
| DNS_NODES                                       | string  | Node name used when running server in a cluster.                                                                                                                                                                                                                                                                                |
| MAX_CONNECTIONS                                 | string  | Set the soft maximum for WebSocket connections. Defaults to '16384'.                                                                                                                                                                                                                                                            |
| MAX_HEADER_LENGTH                               | string  | Set the maximum header length for connections (in bytes). Defaults to '4096'.                                                                                                                                                                                                                                                   |
| NUM_ACCEPTORS                                   | string  | Set the number of server processes that will relay incoming WebSocket connection requests. Defaults to '100'.                                                                                                                                                                                                                   |
| DB_QUEUE_TARGET                                 | string  | Maximum time to wait for a connection from the pool. Defaults to '5000' or 5 seconds. See for more info: [DBConnection](https://hexdocs.pm/db_connection/DBConnection.html#start_link/2-queue-config).                                                                                                                          |
| DB_QUEUE_INTERVAL                               | string  | Interval to wait to check if all connections were checked out under DB_QUEUE_TARGET. If all connections surpassed the target during this interval than the target is doubled. Defaults to '5000' or 5 seconds. See for more info: [DBConnection](https://hexdocs.pm/db_connection/DBConnection.html#start_link/2-queue-config). |
| DB_POOL_SIZE                                    | string  | Sets the number of connections in the database pool. Defaults to '5'.                                                                                                                                                                                                                                                           |
| DB_REPLICA_HOST                                 | string  | Hostname for the replica database. If set, enables the main replica connection pool.                                                                                                                                                                                                                                            |
| DB_REPLICA_POOL_SIZE                            | string  | Sets the number of connections in the replica database pool. Defaults to '5'.                                                                                                                                                                                                                                                   |
| SLOT_NAME_SUFFIX                                | string  | This is appended to the replication slot which allows making a custom slot name. May contain lowercase letters, numbers, and the underscore character. Together with the default `supabase_realtime_replication_slot`, slot name should be up to 64 characters long.                                                            |
| TENANT_CACHE_EXPIRATION_IN_MS                   | string  | Set tenant cache TTL in milliseconds                                                                                                                                                                                                                                                                                            |
| TENANT_MAX_BYTES_PER_SECOND                     | string  | The default value of maximum bytes per second that each tenant can support, used when creating a tenant for the first time. Defaults to '100_000'.                                                                                                                                                                              |
| TENANT_MAX_CHANNELS_PER_CLIENT                  | string  | The default value of maximum number of channels each tenant can support, used when creating a tenant for the first time. Defaults to '100'.                                                                                                                                                                                     |
| TENANT_MAX_CONCURRENT_USERS                     | string  | The default value of maximum concurrent users per channel that each tenant can support, used when creating a tenant for the first time. Defaults to '200'.                                                                                                                                                                      |
| TENANT_MAX_EVENTS_PER_SECOND                    | string  | The default value of maximum events per second that each tenant can support, used when creating a tenant for the first time. Defaults to '100'.                                                                                                                                                                                 |
| TENANT_MAX_JOINS_PER_SECOND                     | string  | The default value of maximum channel joins per second that each tenant can support, used when creating a tenant for the first time. Defaults to '100'.                                                                                                                                                                          |
| CLIENT_PRESENCE_MAX_CALLS                       | number  | Maximum number of presence calls allowed per client (per WebSocket connection) within the time window. Defaults to '5'.                                                                                                                                                                                                         |
| CLIENT_PRESENCE_WINDOW_MS                       | number  | Time window in milliseconds for per-client presence rate limiting. Defaults to '30000' (30 seconds).                                                                                                                                                                                                                            |
| SEED_SELF_HOST                                  | boolean | Seeds the system with default tenant                                                                                                                                                                                                                                                                                            |
| SELF_HOST_TENANT_NAME                           | string  | Tenant reference to be used for self host. Do keep in mind to use a URL compatible name                                                                                                                                                                                                                                         |
| LOG_LEVEL                                       | string  | Sets log level for Realtime logs. Defaults to info, supported levels are: info, emergency, alert, critical, error, warning, notice, debug                                                                                                                                                                                       |
| DISABLE_HEALTHCHECK_LOGGING                     | boolean | Disables request logging for healthcheck endpoints (/healthcheck and /api/tenants/:tenant_id/health). Defaults to false.                                                                                                                                                                                                        |
| RUN_JANITOR                                     | boolean | Do you want to janitor tasks to run                                                                                                                                                                                                                                                                                             |
| JANITOR_SCHEDULE_TIMER_IN_MS                    | number  | Time in ms to run the janitor task                                                                                                                                                                                                                                                                                              |
| JANITOR_SCHEDULE_RANDOMIZE                      | boolean | Adds a randomized value of minutes to the timer                                                                                                                                                                                                                                                                                 |
| JANITOR_RUN_AFTER_IN_MS                         | number  | Tells system when to start janitor tasks after boot                                                                                                                                                                                                                                                                             |
| JANITOR_CLEANUP_MAX_CHILDREN                    | number  | Maximum number of concurrent tasks working on janitor cleanup                                                                                                                                                                                                                                                                   |
| JANITOR_CLEANUP_CHILDREN_TIMEOUT                | number  | Timeout for each async task for janitor cleanup                                                                                                                                                                                                                                                                                 |
| JANITOR_CHUNK_SIZE                              | number  | Number of tenants to process per chunk. Each chunk will be processed by a Task                                                                                                                                                                                                                                                  |
| MIGRATION_PARTITION_SLOTS                       | number  | Number of dynamic supervisor partitions used by the migrations process                                                                                                                                                                                                                                                          |
| CONNECT_PARTITION_SLOTS                         | number  | Number of dynamic supervisor partitions used by the Connect, ReplicationConnect processes                                                                                                                                                                                                                                       |
| METRICS_CLEANER_SCHEDULE_TIMER_IN_MS            | number  | Time in ms to run the Metric Cleaner task                                                                                                                                                                                                                                                                                       |
| METRICS_RPC_TIMEOUT_IN_MS                       | number  | Time in ms to wait for RPC call to fetch Metric per node                                                                                                                                                                                                                                                                        |
| WEBSOCKET_MAX_HEAP_SIZE                         | number  | Max number of bytes to be allocated as heap for the WebSocket transport process. If the limit is reached the process is brutally killed. Defaults to 50MB.                                                                                                                                                                      |
| REQUEST_ID_BAGGAGE_KEY                          | string  | OTEL Baggage key to be used as request id                                                                                                                                                                                                                                                                                       |
| OTEL_SDK_DISABLED                               | boolean | Disable OpenTelemetry tracing completely when 'true'                                                                                                                                                                                                                                                                            |
| OTEL_TRACES_EXPORTER                            | string  | Possible values: `otlp` or `none`. See [https://github.com/open-telemetry/opentelemetry-erlang/tree/v1.4.0/apps#os-environment] for more details on how to configure the traces exporter.                                                                                                                                       |
| OTEL_TRACES_SAMPLER                             | string  | Default to `parentbased_always_on` . More info [here](https://opentelemetry.io/docs/languages/erlang/sampling/#environment-variables)                                                                                                                                                                                           |
| GEN_RPC_TCP_SERVER_PORT                         | number  | Port served by `gen_rpc`. Must be secured just like the Erlang distribution port. Defaults to 5369                                                                                                                                                                                                                              |
| GEN_RPC_TCP_CLIENT_PORT                         | number  | `gen_rpc` connects to another node using this port. Most of the time it should be the same as GEN_RPC_TCP_SERVER_PORT. Defaults to 5369                                                                                                                                                                                         |
| GEN_RPC_SSL_SERVER_PORT                         | number  | Port served by `gen_rpc` secured with TLS. Must also define GEN_RPC_CERTFILE, GEN_RPC_KEYFILE and GEN_RPC_CACERTFILE. If this is defined then only TLS connections will be set-up.                                                                                                                                              |
| GEN_RPC_SSL_CLIENT_PORT                         | number  | `gen_rpc` connects to another node using this port. Most of the time it should be the same as GEN_RPC_SSL_SERVER_PORT. Defaults to 6369                                                                                                                                                                                         |
| GEN_RPC_CERTFILE                                | string  | Path to the public key in PEM format. Only needs to be provided if GEN_RPC_SSL_SERVER_PORT is defined                                                                                                                                                                                                                           |
| GEN_RPC_KEYFILE                                 | string  | Path to the private key in PEM format. Only needs to be provided if GEN_RPC_SSL_SERVER_PORT is defined                                                                                                                                                                                                                          |
| GEN_RPC_CACERTFILE                              | string  | Path to the certificate authority public key in PEM format. Only needs to be provided if GEN_RPC_SSL_SERVER_PORT is defined                                                                                                                                                                                                     |
| GEN_RPC_CONNECT_TIMEOUT_IN_MS                   | number  | `gen_rpc` client connect timeout in milliseconds. Defaults to 10000.                                                                                                                                                                                                                                                            |
| GEN_RPC_SEND_TIMEOUT_IN_MS                      | number  | `gen_rpc` client and server send timeout in milliseconds. Defaults to 10000.                                                                                                                                                                                                                                                    |
| GEN_RPC_SOCKET_IP                               | string  | Interface which `gen_rpc` will bind to. Defaults to "0.0.0.0" (ipv4) which means that all interfaces are going to expose the `gen_rpc` port.                                                                                                                                                                                    |
| GEN_RPC_IPV6_ONLY                               | boolean | Configure `gen_rpc` to use IPv6 only.                                                                                                                                                                                                                                                                                           |
| GEN_RPC_MAX_BATCH_SIZE                          | integer | Configure `gen_rpc` to batch when possible RPC casts. Defaults to 0                                                                                                                                                                                                                                                             |
| GEN_RPC_COMPRESS                                | integer | Configure `gen_rpc` to compress or not payloads. 0 means no compression and 9 max compression level. Defaults to 0.                                                                                                                                                                                                             |
| GEN_RPC_COMPRESSION_THRESHOLD_IN_BYTES          | integer | Configure `gen_rpc` to compress only above a certain threshold in bytes. Defaults to 1000.                                                                                                                                                                                                                                      |
| MAX_GEN_RPC_CLIENTS                             | number  | Max amount of `gen_rpc` TCP connections per node-to-node channel                                                                                                                                                                                                                                                                |
| REBALANCE_CHECK_INTERVAL_IN_MS                  | number  | Time in ms to check if process is in the right region                                                                                                                                                                                                                                                                           |
| NODE_BALANCE_UPTIME_THRESHOLD_IN_MS             | number  | Minimum node uptime in ms before using load-aware node picker. Nodes below this threshold use random selection as their metrics are not yet reliable. Defaults to 5 minutes.                                                                                                                                                    |
| DISCONNECT_SOCKET_ON_NO_CHANNELS_INTERVAL_IN_MS | number  | Time in ms to check if a socket has no channels open and if so, disconnect it                                                                                                                                                                                                                                                   |
| BROADCAST_POOL_SIZE                             | number  | Number of processes to relay Phoenix.PubSub messages across the cluster                                                                                                                                                                                                                                                         |
| PRESENCE_POOL_SIZE                              | number  | Number of tracker processes for Presence feature. Defaults to 10. Higher values improve concurrency for presence tracking across many channels.                                                                                                                                                                                 |
| PRESENCE_BROADCAST_PERIOD_IN_MS                 | number  | Interval in milliseconds to send presence delta broadcasts across the cluster. Defaults to 1500 (1.5 seconds). Lower values increase network traffic but reduce presence sync latency.                                                                                                                                          |
| PRESENCE_PERMDOWN_PERIOD_IN_MS                  | number  | Interval in milliseconds to flag a replica as permanently down and discard its state. Defaults to 1200000 (20 minutes). Must be greater than down_period. Higher values are more forgiving of temporary network issues but slower to clean up truly dead replicas.                                                               |
| POSTGRES_CDC_SCOPE_SHARDS                       | number  | Number of dynamic supervisor partitions used by the Postgres CDC extension. Defaults to 5.                                                                                                                                                                                                                                      |
| USERS_SCOPE_SHARDS                              | number  | Number of dynamic supervisor partitions used by the Users extension. Defaults to 5.                                                                                                                                                                                                                                             |
| REGION_MAPPING                                  | string  | Custom mapping of platform regions to tenant regions. Must be a valid JSON object with string keys and values (e.g., `{"custom-region-1": "us-east-1", "eu-north-1": "eu-west-2"}`). If not provided, uses the default hardcoded region mapping. When set, only the specified mappings are used (no fallback to defaults). |
| METRICS_PUSHER_ENABLED                          | boolean | Enable periodic push of Prometheus metrics. Defaults to 'false'. Requires METRICS_PUSHER_URL to be set.                                                                                                                                                                                                                         |
| METRICS_PUSHER_URL                              | string  | Full URL endpoint to push metrics to (e.g., 'https://example.com/api/v1/import/prometheus'). Required when METRICS_PUSHER_ENABLED is 'true'.                                                                                                                                                                                    |
| METRICS_PUSHER_AUTH                             | string  | Optional authorization header value for metrics pushes (e.g., 'Bearer token'). If not set, requests will be sent without authorization. Keep this secret if used.                                                                                                                                                               |
| METRICS_PUSHER_INTERVAL_MS                      | number  | Interval in milliseconds between metrics pushes. Defaults to '30000' (30 seconds).                                                                                                                                                                                                                                              |
| METRICS_PUSHER_TIMEOUT_MS                       | number  | HTTP request timeout in milliseconds for metrics push operations. Defaults to '15000' (15 seconds).                                                                                                                                                                                                                             |
| METRICS_PUSHER_COMPRESS                         | boolean | Enable gzip compression for metrics payloads. Defaults to 'true'.                                                                                                                                                                                                                                                               |

The OpenTelemetry variables mentioned above are not an exhaustive list of all [supported environment variables](https://opentelemetry.io/docs/languages/sdk-configuration/).

## WebSocket URL

The WebSocket URL is in the following format for local development: `ws://[external_id].localhost:4000/socket/websocket`

If you're using Supabase's hosted Realtime in production the URL is `wss://[project-ref].supabase.co/realtime/v1/websocket?apikey=[anon-token]&log_level=info&vsn=1.0.0"`

## WebSocket Connection Authorization

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

## Error Operational Codes

This is the list of operational codes that can help you understand your deployment and your usage.

| Code                               | Description                                                                                                                                                                                           |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| TopicNameRequired                  | You are trying to use Realtime without a topic name set                                                                                                                                               |
| InvalidJoinPayload                 | The payload provided to Realtime on connect is invalid                                                                                                                                                |
| RealtimeDisabledForConfiguration   | The configuration provided to Realtime on connect will not be able to provide you any Postgres Changes                                                                                                |
| TenantNotFound                     | The tenant you are trying to connect to does not exist                                                                                                                                                |
| ErrorConnectingToWebsocket         | Error when trying to connect to the WebSocket server                                                                                                                                                  |
| ErrorAuthorizingWebsocket          | Error when trying to authorize the WebSocket connection                                                                                                                                               |
| TableHasSpacesInName               | The table you are trying to listen to has spaces in its name which we are unable to support                                                                                                           |
| UnableToDeleteTenant               | Error when trying to delete a tenant                                                                                                                                                                  |
| UnableToSetPolicies                | Error when setting up Authorization Policies                                                                                                                                                          |
| UnableCheckoutConnection           | Error when trying to checkout a connection from the tenant pool                                                                                                                                       |
| UnableToSubscribeToPostgres        | Error when trying to subscribe to Postgres changes                                                                                                                                                    |
| ReconnectSubscribeToPostgres       | Postgres changes still waiting to be subscribed                                                                                                                                                       |
| ChannelRateLimitReached            | The number of channels you can create has reached its limit                                                                                                                                           |
| ConnectionRateLimitReached         | The number of connected clients as reached its limit                                                                                                                                                  |
| ClientJoinRateLimitReached         | The rate of joins per second from your clients has reached the channel limits                                                                                                                         |
| DatabaseConnectionRateLimitReached | The rate of attempts to connect to tenants database has reached the limit                                                                                                                             |
| MessagePerSecondRateLimitReached   | The rate of messages per second from your clients has reached the channel limits                                                                                                                      |
| RealtimeDisabledForTenant          | Realtime has been disabled for the tenant                                                                                                                                                             |
| UnableToConnectToTenantDatabase    | Realtime was not able to connect to the tenant's database                                                                                                                                             |
| DatabaseLackOfConnections          | Realtime was not able to connect to the tenant's database due to not having enough available connections                                                                                              |
| RealtimeNodeDisconnected           | Realtime is a distributed application and this means that one the system is unable to communicate with one of the distributed nodes                                                                   |
| MigrationsFailedToRun              | Error when running the migrations against the Tenant database that are required by Realtime                                                                                                           |
| StartReplicationFailed             | Error when starting the replication and listening of errors for database broadcasting                                                                                                                 |
| ReplicationConnectionTimeout       | Replication connection timed out during initialization                                                                                                                                                |
| ReplicationMaxWalSendersReached    | Maximum number of WAL senders reached in tenant database, check how to increase this value in this [link](https://supabase.com/docs/guides/database/custom-postgres-config#cli-configurable-settings) |
| MigrationCheckFailed               | Check to see if we require to run migrations fails                                                                                                                                                    |
| PartitionCreationFailed            | Error when creating partitions for realtime.messages                                                                                                                                                  |
| ErrorStartingPostgresCDCStream     | Error when starting the Postgres CDC stream which is used for Postgres Changes                                                                                                                        |
| UnknownDataProcessed               | An unknown data type was processed by the Realtime system                                                                                                                                             |
| ErrorStartingPostgresCDC           | Error when starting the Postgres CDC extension which is used for Postgres Changes                                                                                                                     |
| ReplicationSlotBeingUsed           | The replication slot is being used by another transaction                                                                                                                                             |
| PoolingReplicationPreparationError | Error when preparing the replication slot                                                                                                                                                             |
| PoolingReplicationError            | Error when pooling the replication slot                                                                                                                                                               |
| SubscriptionDeletionFailed         | Error when trying to delete a subscription for postgres changes                                                                                                                                       |
| UnableToDeletePhantomSubscriptions | Error when trying to delete subscriptions that are no longer being used                                                                                                                               |
| UnableToCheckProcessesOnRemoteNode | Error when trying to check the processes on a remote node                                                                                                                                             |
| UnhandledProcessMessage            | Unhandled message received by a Realtime process                                                                                                                                                      |
| UnableToTrackPresence              | Error when handling track presence for this socket                                                                                                                                                    |
| UnknownPresenceEvent               | Presence event type not recognized by service                                                                                                                                                         |
| IncreaseConnectionPool             | The number of connections you have set for Realtime are not enough to handle your current use case                                                                                                    |
| RlsPolicyError                     | Error on RLS policy used for authorization                                                                                                                                                            |
| ConnectionInitializing             | Database is initializing connection                                                                                                                                                                   |
| DatabaseConnectionIssue            | Database had connection issues and connection was not able to be established                                                                                                                          |
| UnableToConnectToProject           | Unable to connect to Project database                                                                                                                                                                 |
| InvalidJWTExpiration               | JWT exp claim value it's incorrect                                                                                                                                                                    |
| JwtSignatureError                  | JWT signature was not able to be validated                                                                                                                                                            |
| MalformedJWT                       | Token received does not comply with the JWT format                                                                                                                                                    |
| Unauthorized                       | Unauthorized access to Realtime channel                                                                                                                                                               |
| RealtimeRestarting                 | Realtime is currently restarting                                                                                                                                                                      |
| UnableToProcessListenPayload       | Payload sent in NOTIFY operation was JSON parsable                                                                                                                                                    |
| UnprocessableEntity                | Received a HTTP request with a body that was not able to be processed by the endpoint                                                                                                                 |
| InitializingProjectConnection      | Connection against Tenant database is still starting                                                                                                                                                  |
| TimeoutOnRpcCall                   | RPC request within the Realtime server as timed out.                                                                                                                                                  |
| ErrorOnRpcCall                     | Error when calling another realtime node                                                                                                                                                              |
| ErrorExecutingTransaction          | Error executing a database transaction in tenant database                                                                                                                                             |
| SynInitializationError             | Our framework to syncronize processes has failed to properly startup a connection to the database                                                                                                     |
| JanitorFailedToDeleteOldMessages   | Scheduled task for realtime.message cleanup was unable to run                                                                                                                                         |
| UnableToEncodeJson                 | An error were we are not handling correctly the response to be sent to the end user                                                                                                                   |
| UnknownErrorOnController           | An error we are not handling correctly was triggered on a controller                                                                                                                                  |
| UnknownErrorOnChannel              | An error we are not handling correctly was triggered on a channel                                                                                                                                     |
| PresenceRateLimitReached           | Limit of presence events reached                                                                                                                                                                      |
| ClientPresenceRateLimitReached     | Limit of presence events reached on socket                                                                                                                                                            |
| UnableToReplayMessages             | An error while replaying messages                                                                                                                                                                     |

## Observability and Metrics

Supabase Realtime exposes comprehensive metrics for monitoring performance, resource usage, and application behavior. These metrics are exposed in Prometheus format and can be scraped by any compatible monitoring system.

### Metric Scopes

Metrics are classified by their scope to help you understand what they measure:

- **Per-Tenant**: Metrics tagged with a tenant identifier measure activity scoped to individual tenants. Use these to identify tenant-specific performance issues, resource usage patterns, or anomalies. Per-tenant metrics include a `tenant` label in Prometheus output.
- **Per-Node**: Metrics measure activity on the current Realtime node. Without explicit per-node indication, assume metrics apply to the local node.
- **Global/Cluster**: Metrics prefixed with `realtime_channel_global_*` aggregate data across all nodes in the cluster.
- **BEAM/Erlang VM**: Metrics prefixed with `beam_*` and `phoenix_*` expose Erlang runtime internals.
- **Infrastructure**: Metrics prefixed with `osmon_*`, `gen_rpc_*`, and `dist_*` measure system-level resources and cluster communication.

### Connection & Tenant Metrics

These metrics track WebSocket connections and tenant activity across the Realtime cluster.

| Metric | Type | Description | Scope |
|--------|------|-------------|-------|
| `realtime_tenants_connected` | Gauge | Number of connected tenants per Realtime node. Use this to understand tenant distribution across your cluster and identify load imbalances. | Per-Node |
| `realtime_connections_connected` | Gauge | Active WebSocket connections that have at least one subscribed channel. Indicates active client engagement with Realtime features (broadcast, presence, or postgres_changes). | **Per-Tenant** |
| `realtime_connections_connected_cluster` | Gauge | Cluster-wide active WebSocket connections for each tenant across all nodes. Use this to understand total tenant engagement across the cluster. | **Per-Tenant** |
| `phoenix_connections_total` | Gauge | Total WebSocket connections including those without active channels. Useful for understanding connection overhead and comparing against active connections. | Per-Node |
| `realtime_channel_joins` | Counter | Rate of channel join attempts per second. Monitor this to detect sudden spikes in connection activity or identify problematic clients performing excessive joins. | **Per-Tenant** |

### Event Metrics

These metrics measure the volume and types of events flowing through your Realtime system, segmented by feature type.

| Metric | Type | Description | Scope |
|--------|------|-------------|-------|
| `realtime_channel_events` | Counter | Broadcast events per second. Tracks messages sent through the broadcast feature across all connected clients. | **Per-Tenant** |
| `realtime_channel_presence_events` | Counter | Presence events per second. Includes online/offline status updates and custom presence metadata synchronization. | **Per-Tenant** |
| `realtime_channel_db_events` | Counter | Postgres Changes events per second. Represents database changes that were detected and broadcast to subscribed clients. | **Per-Tenant** |
| `realtime_channel_global_events` | Counter | Global broadcast events per second across the entire cluster. Compare this to single-node broadcasts to understand cross-node event propagation. | Global |
| `realtime_channel_global_presence_events` | Counter | Global presence events per second across the cluster. Monitor this to track cluster-wide presence synchronization overhead. | Global |
| `realtime_channel_global_db_events` | Counter | Global Postgres Changes events per second across the cluster. Indicates how changes propagate and replicate across nodes. | Global |

### Payload & Traffic Metrics

These metrics provide insight into data volume, message sizes, and network I/O characteristics.

| Metric | Type | Description | Scope |
|--------|------|-------------|-------|
| `realtime_payload_size_bucket` | Histogram | Distribution of payload sizes for broadcast, postgres_changes, and presence events across all tenants. Helps identify performance issues caused by large message sizes and optimize payload compression settings. | Per-Node |
| `realtime_tenants_payload_size_bucket` | Histogram | Per-tenant payload size distribution. Use this to identify tenants generating unusually large messages and troubleshoot tenant-specific performance issues. | **Per-Tenant** |
| `realtime_channel_input_bytes` | Counter | Total ingress bytes received by all channels. Track this alongside `output_bytes` to understand asymmetric traffic patterns and capacity planning needs. | **Per-Tenant** |
| `realtime_channel_output_bytes` | Counter | Total egress bytes sent to all clients. Large egress values may indicate inefficient broadcast patterns or excessive event generation. | **Per-Tenant** |

### Latency & Performance Metrics

These metrics measure end-to-end latency and processing performance across different Realtime operations.

| Metric | Type | Description | Scope |
|--------|------|-------------|-------|
| `realtime_replication_poller_query_duration_bucket` | Histogram | Postgres Changes query latency in milliseconds. Includes network I/O to the database and WAL log reading. High values may indicate database performance issues. | **Per-Tenant** |
| `realtime_replication_poller_query_duration_count` | Counter | Number of database polling queries executed per second. Use with query duration to calculate average latency. | **Per-Tenant** |
| `realtime_tenants_broadcast_from_database_latency_committed_at_bucket` | Histogram | Time from database commit to client broadcast, measured from the commit timestamp. Indicates end-to-end latency for database-driven changes. | **Per-Tenant** |
| `realtime_tenants_broadcast_from_database_latency_inserted_at_bucket` | Histogram | Alternative latency measurement using insert timestamp. Useful if commit timestamps are unavailable or for measuring application-layer latency. | **Per-Tenant** |
| `realtime_tenants_replay_bucket` | Histogram | Latency of broadcast replay in milliseconds. Measures time taken to replay messages to newly connected clients. | **Per-Tenant** |
| `realtime_rpc_bucket` | Histogram | Inter-node RPC call duration across the Realtime cluster. Monitor this to identify network issues or overloaded cluster nodes. | Global |
| `realtime_tenants_read_authorization_check_bucket` | Histogram | RLS policy evaluation time for read operations in milliseconds. High values indicate complex RLS policies or database performance issues. | **Per-Tenant** |
| `realtime_tenants_read_authorization_check_count` | Counter | Number of read authorization checks per second. Monitor this alongside bucket metrics to identify high authorization load. | **Per-Tenant** |
| `realtime_tenants_write_authorization_check_bucket` | Histogram | RLS policy evaluation time for write operations in milliseconds. Typically higher than read checks due to more complex policy logic. | **Per-Tenant** |

### Authorization & Error Metrics

These metrics track security policy enforcement and error rates across authorization and RPC operations.

| Metric | Type | Description | Scope |
|--------|------|-------------|-------|
| `realtime_channel_error` | Counter | Unhandled channel errors per second that should not occur during normal operation. Any non-zero value warrants investigation and potential bug reporting. | Per-Node |
| `phoenix_channel_joined_total` | Counter | Total channel join attempts with success/error status. High error rates indicate client configuration issues, insufficient resources, or policy violations. | Per-Node |
| `realtime_global_rpc_count` | Counter | Global RPC success and failure counts across the cluster. Failed RPCs may indicate inter-node communication issues or temporary overload conditions. | Global |

### BEAM/Erlang VM Metrics

These metrics provide insight into the underlying Erlang runtime that powers Realtime, critical for capacity planning and debugging performance issues.

#### Memory Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `beam_memory_allocated_bytes` | Gauge | Total memory allocated by the Erlang VM. Compare this to the container memory limit to ensure you have headroom. Steady increase may indicate a memory leak. |
| `beam_memory_atom_total_bytes` | Gauge | Memory used by the atom table. Atoms in Erlang are never garbage collected, so this should remain relatively stable. Unbounded growth indicates a bug creating new atoms. |
| `beam_memory_binary_total_bytes` | Gauge | Memory used by binary data (WebSocket payloads, database results). This metric closely correlates with active connection volume and message sizes. |
| `beam_memory_code_total_bytes` | Gauge | Memory used by compiled Erlang bytecode. Changes only during code reloads and should remain stable in production. |
| `beam_memory_ets_total_bytes` | Gauge | Memory used by ETS (in-memory tables) including channel subscriptions and presence state. Monitor this to understand session storage overhead. |
| `beam_memory_processes_total_bytes` | Gauge | Memory used by Erlang processes themselves. Each channel connection and background task consumes memory; this scales with concurrency. |
| `beam_memory_persistent_term_total_bytes` | Gauge | Memory used by persistent terms (immutable shared state). Should be minimal and stable in typical Realtime deployments. |

#### Process & Resource Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `beam_stats_process_count` | Gauge | Number of active Erlang processes. Each WebSocket connection spawns processes; high values correlate with connection count. Sudden spikes may indicate process leaks. |
| `beam_stats_port_count` | Gauge | Number of open port connections (network sockets, pipes). Should correlate roughly with connection count plus internal cluster communications. |
| `beam_stats_ets_count` | Gauge | Number of active ETS tables used for caching and state. Changes reflect dynamic supervisor activity and feature usage patterns. |
| `beam_stats_atom_count` | Gauge | Total atoms in the atom table. Should remain relatively stable; unbounded growth indicates code bugs. |

#### Performance Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `beam_stats_uptime_milliseconds_count` | Counter | Node uptime in milliseconds. Use this to track restarts and validate deployment stability. Unexpected resets indicate crashes. |
| `beam_stats_port_io_byte_count` | Counter | Total bytes transferred through network ports. Compare ingress and egress to identify asymmetric traffic patterns. |
| `beam_stats_gc_count` | Counter | Garbage collection events executed by the Erlang VM. Frequent GC indicates high memory churn; infrequent GC suggests stable state. |
| `beam_stats_gc_reclaimed_bytes` | Counter | Bytes reclaimed by garbage collection. Divide by GC count to understand average cleanup size. Low reclaim per GC may indicate inefficient memory allocation patterns. |
| `beam_stats_reduction_count` | Counter | Total reductions (work units) executed by the VM. Correlates with CPU usage; high reduction rates under stable load indicate inefficient algorithms. |
| `beam_stats_context_switch_count` | Counter | Process context switches by the Erlang scheduler. High values indicate contention between many processes; compare with process count to gauge congestion. |
| `beam_stats_active_task_count` | Gauge | Tasks currently executing on dirty schedulers (non-Erlang operations). High values indicate CPU-bound work or blocking I/O. |
| `beam_stats_run_queue_count` | Gauge | Processes waiting to be scheduled. High values indicate CPU saturation; the node cannot keep up with work demand. |

### Infrastructure Metrics

These metrics expose system-level resource usage and inter-node cluster communication.

#### Node Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `osmon_cpu_util` | Gauge | Current CPU utilization percentage (0-100). Monitor this to trigger horizontal scaling and identify CPU-bound bottlenecks. |
| `osmon_cpu_avg1` | Gauge | 1-minute CPU load average. Sharp increases indicate sudden load spikes; values > CPU count indicate sustained overload. |
| `osmon_cpu_avg5` | Gauge | 5-minute CPU load average. Smooths short-term spikes; use this to detect sustained load increases. |
| `osmon_cpu_avg15` | Gauge | 15-minute CPU load average. Indicates long-term trends; use for capacity planning and detecting gradual load growth. |
| `osmon_ram_usage` | Gauge | RAM utilization percentage (0-100). Combined with `beam_memory_allocated_bytes`, this indicates kernel memory overhead and other processes on the node. |

#### Distributed System Metrics

| Metric | Type | Description |
|--------|------|-------------|
| `gen_rpc_queue_size_bytes` | Gauge | Outbound queue size for gen_rpc inter-node communication in bytes. Large values indicate a receiving node cannot keep up with message rate. |
| `gen_rpc_send_pending_bytes` | Gauge | Bytes pending transmission in gen_rpc queues. Combined with queue size, helps identify network saturation or slow receivers. |
| `gen_rpc_send_bytes` | Counter | Total bytes sent via gen_rpc across the cluster. Monitor this to understand inter-node traffic and plan network capacity. |
| `gen_rpc_recv_bytes` | Counter | Total bytes received via gen_rpc from other nodes. Compare with send bytes to identify asymmetric communication patterns. |
| `dist_queue_size` | Gauge | Erlang distribution queue size for cluster communication. High values indicate network congestion or unbalanced load across nodes. |
| `dist_send_pending_bytes` | Gauge | Bytes pending in Erlang distribution queues. Works with queue size to diagnose cluster communication issues. |
| `dist_send_bytes` | Counter | Total bytes sent via Erlang distribution protocol. Includes all cluster metadata and RPC traffic. |
| `dist_recv_bytes` | Counter | Total bytes received via Erlang distribution protocol. Compare with send to validate symmetric communication. |
do
## License

This repo is licensed under Apache 2.0.

## Credits

- [Phoenix](https://github.com/phoenixframework/phoenix) - `Realtime` server is built with the amazing Elixir framework.
- [Phoenix Channels JavaScript Client](https://github.com/phoenixframework/phoenix/tree/master/assets/js/phoenix) - [@supabase/realtime-js](https://github.com/supabase/realtime-js) client library heavily draws from the Phoenix Channels client library.
