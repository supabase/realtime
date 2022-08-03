# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :realtime,
  ecto_repos: [Realtime.Repo]

# Configures the endpoint
config :realtime, RealtimeWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "ktyW57usZxrivYdvLo9os7UGcUUZYKchOMHT3tzndmnHuxD09k+fQnPUmxlPMUI3",
  render_errors: [view: RealtimeWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: Realtime.PubSub,
  live_view: [signing_salt: "wUMBeR8j"]

config :realtime, :phoenix_swagger,
  swagger_files: %{
    "priv/static/swagger.json" => [
      router: RealtimeWeb.Router,
      endpoint: RealtimeWeb.Endpoint
    ]
  }

config :realtime, :extensions,
  postgres: %{
    key: "postgres",
    supervisor: Extensions.Postgres.Supervisor,
    db_settings: Extensions.Postgres.DbSettings
  }

config :phoenix_swagger, json_library: Jason

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :project, :external_id]

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
