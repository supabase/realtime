# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# These defaults mirror the ones in releases.exs, remember not to change one
# without changing the other.
app_port = String.to_integer(System.get_env("PORT", "4000"))
db_host = System.get_env("DB_HOST", "localhost")
db_port = String.to_integer(System.get_env("DB_PORT", "5432"))
db_name = System.get_env("DB_NAME", "postgres")
db_user = System.get_env("DB_USER", "postgres")
db_password = System.get_env("DB_PASSWORD", "postgres")
# HACK: There's probably a better way to set boolean from env
db_ssl = System.get_env("DB_SSL", "true") === "true"
publications = System.get_env("PUBLICATIONS", "[\"supabase_realtime\"]")
slot_name = System.get_env("SLOT_NAME") || :temporary
configuration_file = System.get_env("CONFIGURATION_FILE") || nil

# If the replication lag exceeds the set MAX_REPLICATION_LAG_MB (make sure the value is a positive integer in megabytes) value
# then replication slot named SLOT_NAME (e.g. "realtime") will be dropped and Realtime will
# restart with a new slot.
max_replication_lag_in_mb = String.to_integer(System.get_env("MAX_REPLICATION_LAG_MB", "0"))

# Channels are not secured by default in development and
# are secured by default in production.
secure_channels = System.get_env("SECURE_CHANNELS", "true") != "false"

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
# If IP version is not specified and database host is:
#   - an IP address, then value ("IPv4"/"IPv6") will be disregarded and Realtime will automatically connect via correct version.
#   - a name (e.g. "db.abcd.supabase.co"), then Realtime will connect either via IPv4 or IPv6. It is recommended
#   to specify IP version to prevent potential non-existent domain (NXDOMAIN) errors.
db_ip_version =
  %{"ipv4" => :inet, "ipv6" => :inet6}
  |> Map.fetch(System.get_env("DB_IP_VERSION", "") |> String.downcase())

webhook_headers = System.get_env("WEBHOOK_HEADERS")

config :realtime,
  app_port: app_port,
  db_host: db_host,
  db_port: db_port,
  db_name: db_name,
  db_user: db_user,
  db_password: db_password,
  db_ssl: db_ssl,
  db_ip_version: db_ip_version,
  publications: publications,
  slot_name: slot_name,
  configuration_file: configuration_file,
  secure_channels: secure_channels,
  jwt_secret: jwt_secret,
  jwt_claim_validators: jwt_claim_validators,
  max_replication_lag_in_mb: max_replication_lag_in_mb,
  webhook_default_headers: [{"Content-Type", "application/json"}],
  webhook_headers: webhook_headers

# Configures the endpoint
config :realtime, RealtimeWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: RealtimeWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: Realtime.PubSub,
  secret_key_base: session_secret_key_base

# Configures Elixir's Logger
config :logger, :console,
  format: "$date $time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
