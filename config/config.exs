# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# Channels are not secured by default in development and
# are secured by default in production.
secure_channels = System.get_env("SECURE_CHANNELS") == "true"
presence = System.get_env("PRESENCE", "true") != "false"

api_key = System.get_env("API_KEY")
# Every JWT's claims will be compared (equality checks) to the expected
# claims set in the JSON object.
# e.g.
# Set JWT_CLAIM_VALIDATORS="{\"iss\": \"Issuer\", \"nbf\": 1610078130}"
# Then JWT's "iss" value must equal "Issuer" and "nbf" value
# must equal 1610078130.
jwt_claim_validators = System.get_env("JWT_CLAIM_VALIDATORS", "{}")

db_host = System.get_env("DB_HOST", "localhost")
db_name = System.get_env("DB_NAME", "postgres")
db_user = System.get_env("DB_USER", "postgres")
db_password = System.get_env("DB_PASSWORD", "postgres")
db_port = System.get_env("DB_PORT", "5432")

# Configure your database
config :multiplayer, Multiplayer.Repo,
  username: db_user,
  password: db_password,
  database: db_name,
  hostname: db_host,
  port: db_port,
  show_sensitive_data_on_connection_error: true,
  pool_size: 3,
  prepare: :unnamed,
  queue_target: 5000

config :multiplayer,
  ecto_repos: [Multiplayer.Repo],
  secure_channels: secure_channels,
  jwt_claim_validators: jwt_claim_validators,
  api_key: api_key,
  presence: presence

# Configures the endpoint
config :multiplayer, MultiplayerWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "ktyW57usZxrivYdvLo9os7UGcUUZYKchOMHT3tzndmnHuxD09k+fQnPUmxlPMUI3",
  render_errors: [view: MultiplayerWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: Multiplayer.PubSub,
  live_view: [signing_salt: "wUMBeR8j"]

config :multiplayer, :phoenix_swagger,
  swagger_files: %{
    "priv/static/swagger.json" => [
      router: MultiplayerWeb.Router,
      endpoint: MultiplayerWeb.Endpoint
    ]
  }

config :phoenix_swagger, json_library: Jason

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :logflare_logger_backend,
  url: "https://api.logflare.app",
  flush_interval: 1_000,
  max_batch_size: 50,
  metadata: :all

config :libcluster,
  debug: false,
  topologies: [
    default: [
      # The selected clustering strategy. Required.
      strategy: Cluster.Strategy.Epmd,
      # Configuration for the provided strategy. Optional.
      # config: [hosts: [:"a@127.0.0.1", :"b@127.0.0.1"]],
      # The function to use for connecting nodes. The node
      # name will be appended to the argument list. Optional
      connect: {:net_kernel, :connect_node, []},
      # The function to use for disconnecting nodes. The node
      # name will be appended to the argument list. Optional
      disconnect: {:erlang, :disconnect_node, []},
      # The function to use for listing nodes.
      # This function must return a list of node names. Optional
      list_nodes: {:erlang, :nodes, [:connected]}
    ]
  ]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
