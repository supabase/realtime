# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# These configs mirror the defaults in releases.exs, remember not to change one
# without changing the other.
config :realtime,
  app_hostname: "localhost",
  app_port: 4000,
  db_host: "localhost",
  db_port: 5432,
  db_name: "postgres",
  db_user: "postgres",
  db_password: "postgres",
  db_ssl: true,
  slot_name: :temporary,
  configuration_file: nil

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
