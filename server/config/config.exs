# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

alias Realtime.{PubSub, RLS}
alias RealtimeWeb.{Endpoint, ErrorView}

# These defaults mirror the ones in releases.exs, remember not to change one
# without changing the other.

# Replication mode is either STREAM or RLS. RLS is the new mode
# where changes are polled and broadcast to specific users depending
# on Row Level Security policies.
replication_mode = System.get_env("REPLICATION_MODE", "STREAM")

app_port = System.get_env("PORT", "4000") |> String.to_integer()
db_host = System.get_env("DB_HOST", "localhost")
db_port = System.get_env("DB_PORT", "5432") |> String.to_integer()
db_name = System.get_env("DB_NAME", "postgres")
db_user = System.get_env("DB_USER", "postgres")
db_password = System.get_env("DB_PASSWORD", "postgres")
# HACK: There's probably a better way to set boolean from env
db_ssl = System.get_env("DB_SSL", "false") != "false"
publications = System.get_env("PUBLICATIONS", "[\"supabase_realtime\"]")
slot_name = System.get_env("SLOT_NAME") || :temporary
temporary_slot = is_atom(slot_name) || System.get_env("TEMPORARY_SLOT", "false") == "true"
configuration_file = System.get_env("CONFIGURATION_FILE") || nil

# If the replication lag exceeds the set MAX_REPLICATION_LAG_MB (make sure the value is a positive integer in megabytes) value
# then replication slot named SLOT_NAME (e.g. "realtime") will be dropped and Realtime will
# restart with a new slot.
max_replication_lag_in_mb = System.get_env("MAX_REPLICATION_LAG_MB", "0") |> String.to_integer()

# Channels are not secured by default in development and
# are secured by default in production.
secure_channels = System.get_env("SECURE_CHANNELS", "false") == "true"

# Supports HS algorithm octet keys
# e.g. "95x0oR8jq9unl9pOIx"
jwt_secret = System.get_env("JWT_SECRET", "")

# Every JWT's claims will be compared (equality checks) to the expected
# claims set in the JSON object.
# e.g.
# Set JWT_CLAIM_VALIDATORS="{'iss': 'Issuer', 'nbf': 1610078130}"
# Then JWT's "iss" value must equal "Issuer" and "nbf" value
# must equal 1610078130.
jwt_claim_validators = System.get_env("JWT_CLAIM_VALIDATORS", "{}")

# The secret key base to built the cookie signing/encryption key.
session_secret_key_base =
  System.get_env(
    "SESSION_SECRET_KEY_BASE",
    "Kyvjr42ZvLcY6yzZ7vmRUniE7Bta9tpknEAvpxtaYOa/marmeI1jsqxhIKeu6V51"
  )

# Connect to database via specified IP version. Options are either "IPv4" or "IPv6".
# It is recommended to specify IP version to prevent potential non-existent domain (NXDOMAIN) errors.
db_ip_version =
  Map.get(
    %{"ipv4" => :inet, "ipv6" => :inet6},
    System.get_env("DB_IP_VERSION", "IPv4") |> String.downcase(),
    :inet
  )

# Expose Prometheus metrics
# Defaults to true in development and false in production
expose_metrics = System.get_env("EXPOSE_METRICS", "true") == "true"

webhook_headers = System.get_env("WEBHOOK_HEADERS")

db_reconnect_backoff_min = System.get_env("DB_RECONNECT_BACKOFF_MIN", "100") |> String.to_integer()
db_reconnect_backoff_max = System.get_env("DB_RECONNECT_BACKOFF_MAX", "120000") |> String.to_integer()

replication_poll_interval = System.get_env("REPLICATION_POLL_INTERVAL", "300") |> String.to_integer()
subscription_sync_interval = System.get_env("SUBSCRIPTION_SYNC_INTERVAL", "60000") |> String.to_integer()

# max_record_bytes (default 1MB): Controls the maximum size of a WAL record that will be
# emitted with complete record and old_record data. When the size of the wal2json record
# exceeds max_record_bytes the record and old_record keys are set as empty objects {} and
# the errors output array will contain the string "Error 413: Payload Too Large"
max_record_bytes = System.get_env("MAX_RECORD_BYTES", "1048576") |> String.to_integer()

config :realtime,
  db_host: db_host,
  db_port: db_port,
  db_name: db_name,
  db_user: db_user,
  db_password: db_password,
  db_ssl: db_ssl,
  db_ip_version: db_ip_version,
  publications: publications,
  replication_mode: replication_mode,
  slot_name: slot_name,
  temporary_slot: temporary_slot,
  configuration_file: configuration_file,
  secure_channels: secure_channels,
  jwt_secret: jwt_secret,
  jwt_claim_validators: jwt_claim_validators,
  max_replication_lag_in_mb: max_replication_lag_in_mb,
  expose_metrics: expose_metrics,
  webhook_default_headers: [{"content-type", "application/json"}],
  webhook_headers: webhook_headers,
  replication_poll_interval: replication_poll_interval,
  subscription_sync_interval: subscription_sync_interval,
  max_record_bytes: max_record_bytes

config :realtime,
  ecto_repos: [RLS.Repo]

config :realtime, RLS.Repo,
  database: db_name,
  username: db_user,
  password: db_password,
  hostname: db_host,
  port: db_port,
  pool_size: 1,
  ssl: db_ssl,
  socket_options: [db_ip_version],
  parameters: [
    application_name: "realtime_rls",
    "pg_stat_statements.track": "none"
  ],
  backoff_type: :rand_exp,
  backoff_min: db_reconnect_backoff_min,
  backoff_max: db_reconnect_backoff_max,
  log: false

# Configures the endpoint
config :realtime, Endpoint,
  url: [host: "localhost"],
  http: [port: app_port],
  render_errors: [view: ErrorView, accepts: ~w(html json)],
  pubsub_server: PubSub,
  secret_key_base: session_secret_key_base

# Configures Elixir's Logger
config :logger, :console,
  format: "$date $time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :realtime, Realtime.Metrics.PromEx,
  disabled: !expose_metrics

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
