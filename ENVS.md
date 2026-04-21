# Environment Variables

Most of these variables are used in [runtime.exs](https://github.com/supabase/realtime/blob/main/config/runtime.exs), check it out for more details and usage.

> **Tip**
> Use a [mise.local.toml](https://mise.jdx.dev/configuration.html) file to set values in your local environment (gitignored).

## Table of Contents

- [API_JWT_SECRET](#api_jwt_secret)
- [API_TOKEN_BLOCKLIST](#api_token_blocklist)
- [APP_NAME](#app_name)
- [AWS_EXECUTION_ENV](#aws_execution_env)
- [BROADCAST_POOL_SIZE](#broadcast_pool_size)
- [CF_TEAM_DOMAIN](#cf_team_domain)
- [CHANNEL_ERROR_BACKOFF_MS](#channel_error_backoff_ms)
- [CLIENT_PRESENCE_MAX_CALLS](#client_presence_max_calls)
- [CLIENT_PRESENCE_WINDOW_MS](#client_presence_window_ms)
- [CLUSTER_STRATEGIES](#cluster_strategies)
- [CONNECT_ERROR_BACKOFF_MS](#connect_error_backoff_ms)
- [CONNECT_PARTITION_SLOTS](#connect_partition_slots)
- [DASHBOARD_AUTH](#dashboard_auth)
- [DASHBOARD_PASSWORD](#dashboard_password)
- [DASHBOARD_USER](#dashboard_user)
- [DB_AFTER_CONNECT_QUERY](#db_after_connect_query)
- [DB_ENC_KEY](#db_enc_key)
- [DB_HOST](#db_host)
- [DB_HOST_REPLICA_FRA](#db_host_replica_fra)
- [DB_HOST_REPLICA_IAD](#db_host_replica_iad)
- [DB_HOST_REPLICA_SIN](#db_host_replica_sin)
- [DB_HOST_REPLICA_SJC](#db_host_replica_sjc)
- [DB_IP_VERSION](#db_ip_version)
- [DB_MASTER_REGION](#db_master_region)
- [DB_NAME](#db_name)
- [DB_PASSWORD](#db_password)
- [DB_POOL_SIZE](#db_pool_size)
- [DB_PORT](#db_port)
- [DB_QUEUE_INTERVAL](#db_queue_interval)
- [DB_QUEUE_TARGET](#db_queue_target)
- [DB_REPLICA_HOST](#db_replica_host)
- [DB_REPLICA_POOL_SIZE](#db_replica_pool_size)
- [DB_SSL](#db_ssl)
- [DB_SSL_CA_CERT](#db_ssl_ca_cert)
- [DB_USER](#db_user)
- [DISABLE_HEALTHCHECK_LOGGING](#disable_healthcheck_logging)
- [DNS_NODES](#dns_nodes)
- [ERL_AFLAGS](#erl_aflags)
- [GEN_RPC_CACERTFILE](#gen_rpc_cacertfile)
- [GEN_RPC_CERTFILE](#gen_rpc_certfile)
- [GEN_RPC_COMPRESS](#gen_rpc_compress)
- [GEN_RPC_COMPRESSION_THRESHOLD_IN_BYTES](#gen_rpc_compression_threshold_in_bytes)
- [GEN_RPC_CONNECT_TIMEOUT_IN_MS](#gen_rpc_connect_timeout_in_ms)
- [GEN_RPC_IPV6_ONLY](#gen_rpc_ipv6_only)
- [GEN_RPC_KEYFILE](#gen_rpc_keyfile)
- [GEN_RPC_MAX_BATCH_SIZE](#gen_rpc_max_batch_size)
- [GEN_RPC_SEND_TIMEOUT_IN_MS](#gen_rpc_send_timeout_in_ms)
- [GEN_RPC_SOCKET_IP](#gen_rpc_socket_ip)
- [GEN_RPC_SSL_CLIENT_PORT](#gen_rpc_ssl_client_port)
- [GEN_RPC_SSL_SERVER_PORT](#gen_rpc_ssl_server_port)
- [GEN_RPC_TCP_CLIENT_PORT](#gen_rpc_tcp_client_port)
- [GEN_RPC_TCP_SERVER_PORT](#gen_rpc_tcp_server_port)
- [JANITOR_CHILDREN_TIMEOUT](#janitor_children_timeout)
- [JANITOR_CHUNK_SIZE](#janitor_chunk_size)
- [JANITOR_MAX_CHILDREN](#janitor_max_children)
- [JANITOR_RUN_AFTER_IN_MS](#janitor_run_after_in_ms)
- [JANITOR_SCHEDULE_RANDOMIZE](#janitor_schedule_randomize)
- [JANITOR_SCHEDULE_TIMER_IN_MS](#janitor_schedule_timer_in_ms)
- [JWT_CLAIM_VALIDATORS](#jwt_claim_validators)
- [LOGFLARE_API_KEY](#logflare_api_key)
- [LOGFLARE_LOGGER_BACKEND_URL](#logflare_logger_backend_url)
- [LOGFLARE_SOURCE_ID](#logflare_source_id)
- [LOGS_ENGINE](#logs_engine)
- [LOG_LEVEL](#log_level)
- [LOG_THROTTLE_JANITOR_INTERVAL_IN_MS](#log_throttle_janitor_interval_in_ms)
- [MAX_CONNECTIONS](#max_connections)
- [MAX_GEN_RPC_CALL_CLIENTS](#max_gen_rpc_call_clients)
- [MAX_GEN_RPC_CLIENTS](#max_gen_rpc_clients)
- [MAX_HEADER_LENGTH](#max_header_length)
- [MEASURE_TRAFFIC_INTERVAL_IN_MS](#measure_traffic_interval_in_ms)
- [METRICS_CLEANER_SCHEDULE_TIMER_IN_MS](#metrics_cleaner_schedule_timer_in_ms)
- [METRICS_JWT_SECRET](#metrics_jwt_secret)
- [METRICS_PUSHER_AUTH](#metrics_pusher_auth)
- [METRICS_PUSHER_COMPRESS](#metrics_pusher_compress)
- [METRICS_PUSHER_ENABLED](#metrics_pusher_enabled)
- [METRICS_PUSHER_EXTRA_LABELS](#metrics_pusher_extra_labels)
- [METRICS_PUSHER_INTERVAL_MS](#metrics_pusher_interval_ms)
- [METRICS_PUSHER_TIMEOUT_MS](#metrics_pusher_timeout_ms)
- [METRICS_PUSHER_URL](#metrics_pusher_url)
- [METRICS_PUSHER_USER](#metrics_pusher_user)
- [METRICS_RPC_TIMEOUT_IN_MS](#metrics_rpc_timeout_in_ms)
- [METRICS_TOKEN_BLOCKLIST](#metrics_token_blocklist)
- [MIGRATION_PARTITION_SLOTS](#migration_partition_slots)
- [NODE_BALANCE_UPTIME_THRESHOLD_IN_MS](#node_balance_uptime_threshold_in_ms)
- [NO_CHANNEL_TIMEOUT_IN_MS](#no_channel_timeout_in_ms)
- [NUM_ACCEPTORS](#num_acceptors)
- [OTEL_SDK_DISABLED](#otel_sdk_disabled)
- [OTEL_TRACES_EXPORTER](#otel_traces_exporter)
- [OTEL_TRACES_SAMPLER](#otel_traces_sampler)
- [PORT](#port)
- [POSTGRES_CDC_SCOPE_SHARDS](#postgres_cdc_scope_shards)
- [PRESENCE_BROADCAST_PERIOD_IN_MS](#presence_broadcast_period_in_ms)
- [PRESENCE_PERMDOWN_PERIOD_IN_MS](#presence_permdown_period_in_ms)
- [PRESENCE_POOL_SIZE](#presence_pool_size)
- [PROM_POLL_RATE](#prom_poll_rate)
- [REALTIME_IP_VERSION](#realtime_ip_version)
- [REBALANCE_CHECK_INTERVAL_IN_MS](#rebalance_check_interval_in_ms)
- [REGION](#region)
- [REGION_MAPPING](#region_mapping)
- [REQUEST_ID_BAGGAGE_KEY](#request_id_baggage_key)
- [RPC_TIMEOUT](#rpc_timeout)
- [RUN_JANITOR](#run_janitor)
- [SECRET_KEY_BASE](#secret_key_base)
- [SEED_SELF_HOST](#seed_self_host)
- [SELF_HOST_TENANT_NAME](#self_host_tenant_name)
- [SLOT_NAME_SUFFIX](#slot_name_suffix)
- [TENANT_CACHE_EXPIRATION_IN_MS](#tenant_cache_expiration_in_ms)
- [TENANT_MAX_BYTES_PER_SECOND](#tenant_max_bytes_per_second)
- [TENANT_MAX_CHANNELS_PER_CLIENT](#tenant_max_channels_per_client)
- [TENANT_MAX_CONCURRENT_USERS](#tenant_max_concurrent_users)
- [TENANT_MAX_EVENTS_PER_SECOND](#tenant_max_events_per_second)
- [TENANT_MAX_JOINS_PER_SECOND](#tenant_max_joins_per_second)
- [USERS_SCOPE_SHARDS](#users_scope_shards)
- [WEBSOCKET_MAX_HEAP_SIZE](#websocket_max_heap_size)

## `PORT`

Port which you can connect your client/listeners.

- Type: number
- Required: yes
- Default: `4000`

## `DB_HOST`

Database host URL.

- Type: string
- Required: yes
- Default: `127.0.0.1`

## `DB_PORT`

Database port.

- Type: number
- Required: yes
- Default: `5432`

## `DB_USER`

Database user.

- Type: string
- Required: yes
- Default: `supabase_admin`

## `DB_PASSWORD`

Database password.

- Type: string
- Required: yes
- Default: `postgres`

## `DB_NAME`

Postgres database name.

- Type: string
- Required: yes
- Default: `postgres`

## `DB_ENC_KEY`

Key used to encrypt sensitive fields in `_realtime.tenants` and `_realtime.extensions` tables. Recommended: 16 characters.

- Type: string

## `DB_AFTER_CONNECT_QUERY`

Query that is run after server connects to database.

- Type: string

## `DB_IP_VERSION`

Sets the IP Version to be used for database connections. Allowed values are `ipv6` and `ipv4`. If none are set we will try to infer the correct version.

- Type: string
- Required: yes
- Default: auto-detected from `DB_HOST`

## `REALTIME_IP_VERSION`

Sets the IP Version for the HTTP listener. Allowed values are `ipv6` and `ipv4`. If none are set we will try to detect IPv6 support and fall back to IPv4.

- Type: string
- Default: auto-detected

## `DB_SSL`

Whether or not the connection will be set-up using SSL.

- Type: boolean
- Required: yes
- Default: `false`

## `DB_SSL_CA_CERT`

Filepath to a CA trust store (e.g.: `/etc/cacert.pem`). If defined it enables server certificate verification.

- Type: string

## `API_JWT_SECRET`

Secret that is used to sign tokens used to manage tenants and their extensions via HTTP requests.

- Type: string

## `API_TOKEN_BLOCKLIST`

Comma-separated list of tokens blocked for tenant management API access.

- Type: string
- Default: empty

## `SECRET_KEY_BASE`

Secret used by the server to sign cookies. Recommended: 64 characters.

- Type: string
- Required: in `prod`

## `ERL_AFLAGS`

Set to either `-proto_dist inet_tcp` or `-proto_dist inet6_tcp` depending on whether or not your network uses IPv4 or IPv6, respectively.

- Type: string

## `APP_NAME`

A name of the server.

- Type: string
- Required: in `prod`
- Default: `""`

## `CLUSTER_STRATEGIES`

Comma-separated cluster backends to enable. Supported values are `EPMD`, `DNS`, and `POSTGRES`.

- Type: string
- Default: `POSTGRES` in prod, `EPMD` otherwise

## `DNS_NODES`

Node name used when running server in a cluster.

- Type: string
- Required: if `DNS` clustering

## `DB_MASTER_REGION`

Overrides the primary region used for region-aware routing and tenant placement. If not set, Realtime uses the current `REGION`.

- Type: string
- Default: `REGION`

## `MAX_CONNECTIONS`

Set the soft maximum for WebSocket connections.

- Type: number
- Default: `1000`

## `MAX_HEADER_LENGTH`

Set the maximum header length for connections (in bytes).

- Type: number
- Default: `4096`

## `NUM_ACCEPTORS`

Set the number of server processes that will relay incoming WebSocket connection requests.

- Type: number
- Default: `100`

## `DB_QUEUE_TARGET`

Maximum time to wait for a connection from the pool in milliseconds. See for more info: [DBConnection](https://hexdocs.pm/db_connection/DBConnection.html#start_link/2-queue-config).

- Type: number
- Default: `5000`

## `DB_QUEUE_INTERVAL`

Interval to wait to check if all connections were checked out under DB_QUEUE_TARGET in milliseconds. If all connections surpassed the target during this interval than the target is doubled. See for more info: [DBConnection](https://hexdocs.pm/db_connection/DBConnection.html#start_link/2-queue-config).

- Type: number
- Default: `5000`

## `DB_POOL_SIZE`

Sets the number of connections in the database pool.

- Type: number
- Default: `5`

## `DB_REPLICA_HOST`

Hostname for the replica database. If set, enables the main replica connection pool.

- Type: string

## `DB_HOST_REPLICA_FRA`

Hostname for the FRA replica database used by the legacy replica repos.

- Type: string
- Default: `DB_HOST`

## `DB_HOST_REPLICA_IAD`

Hostname for the IAD replica database used by the legacy replica repos.

- Type: string
- Default: `DB_HOST`

## `DB_HOST_REPLICA_SIN`

Hostname for the SIN replica database used by the legacy replica repos.

- Type: string
- Default: `DB_HOST`

## `DB_HOST_REPLICA_SJC`

Hostname for the SJC replica database used by the legacy replica repos.

- Type: string
- Default: `DB_HOST`

## `DB_REPLICA_POOL_SIZE`

Sets the number of connections in the replica database pool.

- Type: number
- Default: `5`

## `SLOT_NAME_SUFFIX`

This is appended to the replication slot which allows making a custom slot name. May contain lowercase letters, numbers, and the underscore character. Together with the default `supabase_realtime_replication_slot`, slot name should be up to 64 characters long.

- Type: string

## `TENANT_CACHE_EXPIRATION_IN_MS`

Set tenant cache TTL in milliseconds.

- Type: number
- Default: `30_000`

## `TENANT_MAX_BYTES_PER_SECOND`

The default value of maximum bytes per second that each tenant can support, used when creating a tenant for the first time.

- Type: number
- Default: `100_000`

## `TENANT_MAX_CHANNELS_PER_CLIENT`

The default value of maximum number of channels each tenant can support, used when creating a tenant for the first time.

- Type: number
- Default: `100`

## `TENANT_MAX_CONCURRENT_USERS`

The default value of maximum concurrent users per channel that each tenant can support, used when creating a tenant for the first time.

- Type: number
- Default: `200`

## `TENANT_MAX_EVENTS_PER_SECOND`

The default value of maximum events per second that each tenant can support, used when creating a tenant for the first time.

- Type: number
- Default: `100`

## `TENANT_MAX_JOINS_PER_SECOND`

The default value of maximum channel joins per second that each tenant can support, used when creating a tenant for the first time.

- Type: number
- Default: `100`

## `CLIENT_PRESENCE_MAX_CALLS`

Maximum number of presence calls allowed per client (per WebSocket connection) within the time window.

- Type: number
- Default: `5`

## `CLIENT_PRESENCE_WINDOW_MS`

Time window in milliseconds for per-client presence rate limiting.

- Type: number
- Default: `30_000`

## `SEED_SELF_HOST`

Seeds the system with default tenant.

- Type: boolean

## `SELF_HOST_TENANT_NAME`

Tenant reference to be used for self host. Do keep in mind to use a URL compatible name.

- Type: string

## `REGION`

Region name for the current node. Used in logs, latency reporting, and region-aware routing.

- Type: string

## `LOG_LEVEL`

Sets log level for Realtime logs. Supported levels are: `info`, `emergency`, `alert`, `critical`, `error`, `warning`, `notice`, `debug`.

- Type: string
- Default: `info`

## `LOGS_ENGINE`

Log backend selector. Set to `logflare` to enable the Logflare HTTP backend. If unset, standard logger output is used.

- Type: string

## `LOGFLARE_LOGGER_BACKEND_URL`

Endpoint used by the Logflare logger backend.

- Type: string
- Default: `https://api.logflare.app`

## `LOGFLARE_API_KEY`

API key required when `LOGS_ENGINE=logflare`.

- Type: string
- Required: if `LOGS_ENGINE=logflare`

## `LOGFLARE_SOURCE_ID`

Source ID required when `LOGS_ENGINE=logflare`.

- Type: string
- Required: if `LOGS_ENGINE=logflare`

## `DISABLE_HEALTHCHECK_LOGGING`

Disables request logging for healthcheck endpoints (`/healthcheck` and `/api/tenants/:tenant_id/health`).

- Type: boolean
- Default: `false`

## `RUN_JANITOR`

Do you want to janitor tasks to run.

- Type: boolean
- Default: `false`

## `JANITOR_SCHEDULE_TIMER_IN_MS`

Time in ms to run the janitor task.

- Type: number
- Default: `14_400_000` (4h)

## `JANITOR_SCHEDULE_RANDOMIZE`

Adds a randomized value of minutes to the timer.

- Type: boolean
- Default: `true`

## `JANITOR_RUN_AFTER_IN_MS`

Tells system when to start janitor tasks after boot.

- Type: number
- Default: `600_000` (10m)

## `JANITOR_MAX_CHILDREN`

Maximum number of concurrent tasks working on janitor cleanup.

- Type: number
- Default: `5`

## `JANITOR_CHILDREN_TIMEOUT`

Timeout in milliseconds for each janitor child task.

- Type: number
- Default: `5000`

## `JANITOR_CHUNK_SIZE`

Number of tenants to process per chunk. Each chunk will be processed by a Task.

- Type: number
- Default: `10`

## `LOG_THROTTLE_JANITOR_INTERVAL_IN_MS`

Interval in milliseconds between throttled janitor log emissions.

- Type: number
- Default: `600_000` (10m)

## `MIGRATION_PARTITION_SLOTS`

Number of dynamic supervisor partitions used by the migrations process.

- Type: number
- Default: `schedulers_online * 2`

## `CONNECT_PARTITION_SLOTS`

Number of dynamic supervisor partitions used by the Connect, ReplicationConnect processes.

- Type: number
- Default: `schedulers_online * 2`

## `MEASURE_TRAFFIC_INTERVAL_IN_MS`

Interval in milliseconds to measure traffic per tenant.

- Type: number
- Default: `10_000` (10s)

## `METRICS_CLEANER_SCHEDULE_TIMER_IN_MS`

Time in ms to run the Metric Cleaner task.

- Type: number
- Default: `1_800_000` (30m)

## `METRICS_RPC_TIMEOUT_IN_MS`

Time in ms to wait for RPC call to fetch Metric per node.

- Type: number
- Default: `15_000`

## `NO_CHANNEL_TIMEOUT_IN_MS`

Time in milliseconds after which a WebSocket connection with no joined channels is closed.

- Type: number
- Default: `600_000` (10m)

## `WEBSOCKET_MAX_HEAP_SIZE`

Max number of bytes to be allocated as heap for the WebSocket transport process. If the limit is reached the process is brutally killed.

- Type: number
- Default: `50_000_000` (50MB)

## `REQUEST_ID_BAGGAGE_KEY`

OTEL Baggage key to be used as request id.

- Type: string
- Default: `request-id`

## `JWT_CLAIM_VALIDATORS`

JSON object of claim validators applied to incoming JWTs, for example `{"iss":"Issuer"}`.

- Type: string
- Default: `{}`

## `METRICS_JWT_SECRET`

Secret used to sign JWTs for metrics endpoints.

- Type: string
- Required: outside `test`

## `METRICS_TOKEN_BLOCKLIST`

Comma-separated list of tokens blocked from metrics access.

- Type: string
- Default: empty

## `OTEL_SDK_DISABLED`

Disable OpenTelemetry tracing completely when `true`.

- Type: boolean
- Default: see OTEL defaults

## `OTEL_TRACES_EXPORTER`

Possible values: `otlp` or `none`. See [opentelemetry-erlang](https://github.com/open-telemetry/opentelemetry-erlang/tree/v1.4.0/apps#os-environment) for more details.

- Type: string
- Default: see OTEL defaults

## `OTEL_TRACES_SAMPLER`

More info [here](https://opentelemetry.io/docs/languages/erlang/sampling/#environment-variables).

- Type: string
- Default: `parentbased_always_on`

## `GEN_RPC_TCP_SERVER_PORT`

Port served by `gen_rpc`. Must be secured just like the Erlang distribution port.

- Type: number
- Default: `5369`

## `GEN_RPC_TCP_CLIENT_PORT`

`gen_rpc` connects to another node using this port. Most of the time it should be the same as `GEN_RPC_TCP_SERVER_PORT`.

- Type: number
- Default: `5369`

## `GEN_RPC_SSL_SERVER_PORT`

Port served by `gen_rpc` secured with TLS. Must also define `GEN_RPC_CERTFILE`, `GEN_RPC_KEYFILE` and `GEN_RPC_CACERTFILE`. If this is defined then only TLS connections will be set-up.

- Type: number

## `GEN_RPC_SSL_CLIENT_PORT`

`gen_rpc` connects to another node using this port. Most of the time it should be the same as `GEN_RPC_SSL_SERVER_PORT`.

- Type: number
- Default: `6369`

## `GEN_RPC_CERTFILE`

Path to the public key in PEM format.

- Type: string
- Required: if `GEN_RPC_SSL_SERVER_PORT`

## `GEN_RPC_KEYFILE`

Path to the private key in PEM format.

- Type: string
- Required: if `GEN_RPC_SSL_SERVER_PORT`

## `GEN_RPC_CACERTFILE`

Path to the certificate authority public key in PEM format.

- Type: string
- Required: if `GEN_RPC_SSL_SERVER_PORT`

## `GEN_RPC_CONNECT_TIMEOUT_IN_MS`

`gen_rpc` client connect timeout in milliseconds.

- Type: number
- Default: `10_000`

## `GEN_RPC_SEND_TIMEOUT_IN_MS`

`gen_rpc` client and server send timeout in milliseconds.

- Type: number
- Default: `10_000`

## `GEN_RPC_SOCKET_IP`

Interface which `gen_rpc` will bind to. By default all interfaces are going to expose the `gen_rpc` port.

- Type: string
- Default: `0.0.0.0`

## `GEN_RPC_IPV6_ONLY`

Configure `gen_rpc` to use IPv6 only.

- Type: boolean
- Default: `false`

## `GEN_RPC_MAX_BATCH_SIZE`

Configure `gen_rpc` to batch when possible RPC casts.

- Type: integer
- Default: `0`

## `GEN_RPC_COMPRESS`

Configure `gen_rpc` to compress or not payloads. `0` means no compression and `9` max compression level.

- Type: integer
- Default: `0`

## `GEN_RPC_COMPRESSION_THRESHOLD_IN_BYTES`

Configure `gen_rpc` to compress only above a certain threshold in bytes.

- Type: integer
- Default: `1000`

## `MAX_GEN_RPC_CLIENTS`

Max amount of `gen_rpc` TCP connections per node-to-node channel.

- Type: number
- Default: `5`

## `MAX_GEN_RPC_CALL_CLIENTS`

Max amount of `gen_rpc` TCP call connections per node-to-node channel.

- Type: number
- Default: `1`

## `REBALANCE_CHECK_INTERVAL_IN_MS`

Time in ms to check if process is in the right region.

- Type: number
- Default: `600_000` (10m)

## `RPC_TIMEOUT`

Timeout in milliseconds for internal RPC calls between cluster nodes.

- Type: number
- Default: `30_000` (30s)

## `NODE_BALANCE_UPTIME_THRESHOLD_IN_MS`

Minimum node uptime in ms before using load-aware node picker. Nodes below this threshold use random selection as their metrics are not yet reliable.

- Type: number
- Default: `300_000` (5m)

## `CONNECT_ERROR_BACKOFF_MS`

Time in ms to wait before returning a connection error to the client. Applied to all WebSocket connection failures (invalid JWT, tenant not found, rate limits, etc.). Acts as a backoff to slow down reconnection storms.

- Type: number
- Default: `2_000`

## `CHANNEL_ERROR_BACKOFF_MS`

Time in ms to wait before returning a channel join error to the client. Applied to all channel join failures (invalid JWT, rate limits, DB unavailable, etc.) including unexpected exceptions. Acts as a backoff to slow down reconnection storms.

- Type: number
- Default: `5000`

## `BROADCAST_POOL_SIZE`

Number of processes to relay Phoenix.PubSub messages across the cluster.

- Type: number
- Default: `10`

## `PRESENCE_POOL_SIZE`

Number of tracker processes for Presence feature. Higher values improve concurrency for presence tracking across many channels.

- Type: number
- Default: `10`

## `PRESENCE_BROADCAST_PERIOD_IN_MS`

Interval in milliseconds to send presence delta broadcasts across the cluster. Lower values increase network traffic but reduce presence sync latency.

- Type: number
- Default: `1500`

## `PRESENCE_PERMDOWN_PERIOD_IN_MS`

Interval in milliseconds to flag a replica as permanently down and discard its state. Must be greater than down_period. Higher values are more forgiving of temporary network issues but slower to clean up truly dead replicas.

- Type: number
- Default: `1_200_000` (20m)

## `POSTGRES_CDC_SCOPE_SHARDS`

Number of dynamic supervisor partitions used by the Postgres CDC extension.

- Type: number
- Default: `5`

## `USERS_SCOPE_SHARDS`

Number of dynamic supervisor partitions used by the Users extension.

- Type: number
- Default: `5`

## `PROM_POLL_RATE`

Poll interval in milliseconds for PromEx metrics collection.

- Type: number
- Default: `5000`

## `REGION_MAPPING`

Custom mapping of platform regions to tenant regions. Must be a valid JSON object with string keys and values (e.g., `{"custom-region-1": "us-east-1", "eu-north-1": "eu-west-2"}`). If not provided, uses the default hardcoded region mapping. When set, only the specified mappings are used (no fallback to defaults).

- Type: string
- Default: built-in mapping

## `AWS_EXECUTION_ENV`

Used to detect whether Realtime is running on ECS Fargate. When set to `AWS_ECS_FARGATE`, switches to AWS-specific behavior.

- Type: string
- Default: Fly platform behavior

## `METRICS_PUSHER_ENABLED`

Enable periodic push of Prometheus metrics. Requires `METRICS_PUSHER_URL` to be set.

- Type: boolean
- Default: `false`

## `METRICS_PUSHER_URL`

Full URL endpoint to push metrics using Prometheus exposition format (e.g., `https://example.com/api/v1/import/prometheus`).

- Type: string
- Required: if `METRICS_PUSHER_ENABLED=true`

## `METRICS_PUSHER_USER`

Username for Basic auth (RFC 7617) on metrics pushes. Used together with `METRICS_PUSHER_AUTH` to form the `Authorization` header.

- Type: string
- Default: `realtime`

## `METRICS_PUSHER_AUTH`

Password for Basic auth (RFC 7617) on metrics pushes. If not set, requests will be sent without authorization.

- Type: string

## `METRICS_PUSHER_INTERVAL_MS`

Interval in milliseconds between metrics pushes.

- Type: number
- Default: `30_000` (30s)

## `METRICS_PUSHER_TIMEOUT_MS`

HTTP request timeout in milliseconds for metrics push operations.

- Type: number
- Default: `15_000` (15s)

## `METRICS_PUSHER_COMPRESS`

Enable gzip compression for metrics payloads.

- Type: boolean
- Default: `true`

## `METRICS_PUSHER_EXTRA_LABELS`

Comma-separated list of `key=value` pairs appended as `extra_label` query parameters on each metrics push (e.g., `region=us-east-1,env=prod`). Useful for label injection supported by systems like VictoriaMetrics.

- Type: string
- Default: `""`

## `DASHBOARD_AUTH`

Authentication method for the admin dashboard (`/admin`). Accepted values are `basic_auth` or `zta`. When `basic_auth`, `DASHBOARD_USER` and `DASHBOARD_PASSWORD` are required. When `zta`, `CF_TEAM_DOMAIN` is required.

- Type: string
- Default: `basic_auth`

## `DASHBOARD_USER`

Username for admin dashboard basic auth. Required when `DASHBOARD_AUTH=basic_auth`.

- Type: string
- Default: random 24-char hex

## `DASHBOARD_PASSWORD`

Password for admin dashboard basic auth. Required when `DASHBOARD_AUTH=basic_auth`.

- Type: string
- Default: random 24-char hex

## `CF_TEAM_DOMAIN`

Cloudflare Zero Trust team domain used for ZTA authentication.

- Type: string
- Required: if `DASHBOARD_AUTH=zta`

The OpenTelemetry variables mentioned above are not an exhaustive list of all [supported environment variables](https://opentelemetry.io/docs/languages/sdk-configuration/).
