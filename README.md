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

| Features         | v1  | v2  | Status |
| ---------------- | --- | --- | ------ |
| Postgres Changes | ✔  | ✔  | GA     |
| Broadcast        |     | ✔  | Beta   |
| Presence         |     | ✔  | Beta   |

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

You can check out the [Multiplayer demo](https://multiplayer.dev) that features Broadcast, Presence and Postgres Changes under the demo directory: https://github.com/supabase/realtime/tree/main/demo.

## Client libraries

- JavaScript: [@supabase/realtime-js](https://github.com/supabase/realtime-js)
- Dart: [@supabase/realtime-dart](https://github.com/supabase/realtime-dart)

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

**ALL RELEVANT OPTIONS**

> **Note**
> Realtime server is tightly coupled to [Fly.io](https://fly.io) at the moment.

```sh
PORT                       # {number}      Port which you can connect your client/listeners
DB_HOST                    # {string}      Database host URL
DB_PORT                    # {number}      Database port
DB_USER                    # {string}      Database user
DB_PASSWORD                # {string}      Database password
DB_NAME                    # {string}      Postgres database name
DB_ENC_KEY                 # {string}      Key used to encrypt sensitive fields in _realtime.tenants and _realtime.extensions tables. Recommended: 16 characters.
DB_AFTER_CONNECT_QUERY     # {string}      Query that is run after server connects to database.
API_JWT_SECRET             # {string}      Secret that is used to sign tokens used to manage tenants and their extensions via HTTP requests.
FLY_ALLOC_ID               # {string}      This is auto-set when deploying to Fly. Otherwise, set to any string.
FLY_APP_NAME               # {string}      A name of the server.
FLY_REGION                 # {string}        Name of the region that the server is running in. Fly auto-sets this on deployment. Otherwise, set to any string.
SECRET_KEY_BASE            # {string}      Secret used by the server to sign cookies. Recommended: 64 characters.
ERL_AFLAGS                 # {string}      Set to either "-proto_dist inet_tcp" or "-proto_dist inet6_tcp" depending on whether or not your network uses IPv4 or IPv6, respectively.
ENABLE_TAILSCALE           # {string}      Use Tailscale for private networking. Set to either 'true' or 'false'.
TAILSCALE_APP_NAME         # {string}      Name of the Tailscale app.
TAILSCALE_AUTHKEY          # {string}      Auth key for the Tailscape app.
DNS_NODES                  # {string}      Node name used when running server in a cluster.
MAX_CONNECTIONS            # {string}     Set the soft maximum for WebSocket connections. Defaults to '16384'.
MAX_HEADER_LENGTH          # {string}      Set the maximum header length for connections (in bytes). Defaults to '4096'.
NUM_ACCEPTORS              # {string}     Set the number of server processes that will relay incoming WebSocket connection requests. Defaults to '100'.
DB_QUEUE_TARGET            # {string}     Maximum time to wait for a connection from the pool. Defaults to '5000' or 5 seconds. See for more info: https://hexdocs.pm/db_connection/DBConnection.html#start_link/2-queue-config.
DB_QUEUE_INTERVAL          # {string}     Interval to wait to check if all connections were checked out under DB_QUEUE_TARGET. If all connections surpassed the target during this interval than the target is doubled. Defaults to '5000' or 5 seconds. See for more info: https://hexdocs.pm/db_connection/DBConnection.html#start_link/2-queue-config.
DB_POOL_SIZE               # {string}     Sets the number of connections in the database pool. Defaults to '5'.
SLOT_NAME_SUFFIX           # {string}     This is appended to the replication slot which allows making a custom slot name. May contain lowercase letters, numbers, and the underscore character. Together with the default `supabase_realtime_replication_slot`, slot name should be up to 64 characters long.
```

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

| Code                               | Description                                                                                                                         | Action                                                                                             |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| RealtimeDisabledForConfiguration   | The configuration provided to Realtime on connect will not be able to provide you any Postgres Changes                              | Verify your configuration on channel startup as you might not have your tables properly registered |
| TenantNotFound                     | The tenant you are trying to connect to does not exist                                                                              | Verify the tenant name you are trying to connect to exists in the realtime.tenants table           |
| ErrorConnectingToWebsocket         | Error when trying to connect to the WebSocket server                                                                                | Verify user information on connect                                                                 |
| ErrorAuthorizingWebsocket          | Error when trying to authorize the WebSocket connection                                                                             | Verify user information on connect                                                                 |
| TableHasSpacesInName               | The table you are trying to listen to has spaces in its name which we are unable to support                                         | Change the table name to not have spaces in it                                                     |
| UnableToDeleteTenant               | Error when trying to delete a tenant                                                                                                | Contact Support                                                                                    |
| UnableToSetPolicies                | Error when setting up Authorization Policies                                                                                        | Contact Support                                                                                    |
| UnableCheckoutConnection           | Error when trying to checkout a connection from the tenant pool                                                                     | Contact Support                                                                                    |
| UnableToSubscribeToPostgres        | Error when trying to subscribe to Postgres changes                                                                                  | Contact Support                                                                                    |
| ChannelRateLimitReached            | The number of channels you can create has reached its limit                                                                         | Contact support to increase your rate limits                                                       |
| ConnectionRateLimitReached         | The number of connected clients as reached its limit                                                                                | Contact support to increase your rate limits                                                       |
| ClientJoinRateLimitReached         | The rate of joins per second from your clients as reached the channel limits                                                        | Contact support to increase your rate limits                                                       |
| UnableToConnectToTenantDatabase    | Realtime was not able to connect to the tenant's database                                                                           | Contact support for further instructions                                                           |
| RealtimeNodeDisconnected           | Realtime is a distributed application and this means that one the system is unable to communicate with one of the distributed nodes | Contact support for further instructions                                                           |
| MigrationsFailedToRun              | Error when running the migrations against the Tenant database that are required by Realtime                                         | Contact support for further instructions                                                           |
| ErrorStartingPostgresCDCStream     | Error when starting the Postgres CDC stream which is used for Postgres Changes                                                      | Contact support for further instructions                                                           |
| UnknownDataProcessed               | An unknown data type was processed by the Realtime system                                                                           | Contact support for further instructions                                                           |
| ErrorStartingPostgresCDC           | Error when starting the Postgres CDC extension which is used for Postgres Changes                                                   | Contact support for further instructions                                                           |
| ReplicationSlotBeingUsed           | The replication slot is being used by another transaction                                                                           | Contact support for further instructions                                                           |
| PoolingReplicationPreparationError | Error when preparing the replication slot                                                                                           | Contact support for further instructions                                                           |
| PoolingReplicationError            | Error when pooling the replication slot                                                                                             | Contact support for further instructions                                                           |
| SubscriptionDeletionFailed         | Error when trying to delete a subscription for postgres changes                                                                     | Contact support for further instructions                                                           |
| UnableToDeletePhantomSubscriptions | Error when trying to delete subscriptions that are no longer being used                                                             | Contact support for further instructions                                                           |
| UnableToCheckProcessesOnRemoteNode | Error when trying to check the processes on a remote node                                                                           | Contact support for further instructions                                                           |
| UnableToCreateCounter              | Error when trying to create a counter to track rate limits for a tenant                                                             | Contact support for further instructions                                                           |
| UnableToIncrementCounter           | Error when trying to increment a counter to track rate limits for a tenant                                                          | Contact support for further instructions                                                           |
| UnableToDecrementCounter           | Error when trying to decrement a counter to track rate limits for a tenant                                                          | Contact support for further instructions                                                           |
| UnableToUpdateCounter              | Error when trying to update a counter to track rate limits for a tenant                                                             | Contact support for further instructions                                                           |
| UnableToFindCounter                | Error when trying to find a counter to track rate limits for a tenant                                                               | Contact support for further instructions                                                           |
| UnhandledProcessMessage            | Unhandled message received by a Realtime process                                                                                    | Contact support for further instructions                                                           |
| UnknownError                       | An unknown error occurred                                                                                                           | Contact support for further instructions                                                           |

## License

This repo is licensed under Apache 2.0.

## Credits

- [Phoenix](https://github.com/phoenixframework/phoenix) - `Realtime` server is built with the amazing Elixir framework.
- [Phoenix Channels JavaScript Client](https://github.com/phoenixframework/phoenix/tree/master/assets/js/phoenix) - [@supabase/realtime-js](https://github.com/supabase/realtime-js) client library heavily draws from the Phoenix Channels client library.
