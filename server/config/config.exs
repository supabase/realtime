# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# These defaults mirror the ones in config.exs, remember not to change one
# without changing the other.
app_hostname = System.get_env("HOSTNAME", "localhost")
app_port = String.to_integer(System.get_env("PORT", "4000"))
db_host = System.get_env("DB_HOST", "localhost")
db_port = String.to_integer(System.get_env("DB_PORT", "5432"))
db_name = System.get_env("DB_NAME", "postgres")
db_user = System.get_env("DB_USER", "postgres")
db_password = System.get_env("DB_PASSWORD", "postgres")
# HACK: There's probably a better way to set boolean from env
db_ssl = System.get_env("DB_SSL", "true") === "true"
# Initial delay defaults to half a second
db_retry_initial_delay = System.get_env("DB_RETRY_INITIAL_DELAY", "500")
# Maximum delay defaults to five minutes
db_retry_maximum_delay = System.get_env("DB_RETRY_MAXIMUM_DELAY", "300000")
# Jitter will randomly adjust each delay within 10% of its value
db_retry_jitter = System.get_env("DB_RETRY_JITTER", "10")
slot_name = System.get_env("SLOT_NAME") || :temporary
configuration_file = System.get_env("CONFIGURATION_FILE") || nil

config :realtime,
  app_hostname: app_hostname,
  app_port: app_port,
  db_host: db_host,
  db_port: db_port,
  db_name: db_name,
  db_user: db_user,
  db_password: db_password,
  db_ssl: db_ssl,
  db_retry_initial_delay: db_retry_initial_delay,
  db_retry_maximum_delay: db_retry_maximum_delay,
  db_retry_jitter: db_retry_jitter,
  slot_name: slot_name,
  configuration_file: configuration_file

# Configures the endpoint
config :realtime, RealtimeWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: RealtimeWeb.ErrorView, accepts: ~w(html json)],
  pubsub: [name: Realtime.PubSub, adapter: Phoenix.PubSub.PG2]

# Configures Elixir's Logger
config :logger, :console,
  format: "$date $time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
