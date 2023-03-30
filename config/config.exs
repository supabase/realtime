# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :realtime,
  ecto_repos: [Realtime.Repo],
  version: Mix.Project.config()[:version]

# Configures the endpoint
config :realtime, RealtimeWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "ktyW57usZxrivYdvLo9os7UGcUUZYKchOMHT3tzndmnHuxD09k+fQnPUmxlPMUI3",
  render_errors: [view: RealtimeWeb.ErrorView, accepts: ~w(html json), layout: false],
  pubsub_server: Realtime.PubSub,
  live_view: [signing_salt: "wUMBeR8j"]

config :realtime, :extensions,
  postgres_cdc_rls: %{
    type: :postgres_cdc,
    key: "postgres_cdc_rls",
    driver: Extensions.PostgresCdcRls,
    supervisor: Extensions.PostgresCdcRls.Supervisor,
    db_settings: Extensions.PostgresCdcRls.DbSettings
  },
  postgres_cdc_stream: %{
    type: :postgres_cdc,
    key: "postgres_cdc_stream",
    driver: Extensions.PostgresCdcStream,
    supervisor: Extensions.PostgresCdcStream.Supervisor,
    db_settings: Extensions.PostgresCdcStream.DbSettings
  }

config :esbuild,
  version: "0.14.29",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.1.8",
  default: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :project, :external_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

config :open_api_spex, :cache_adapter, OpenApiSpex.Plug.PersistentTermCache

config :logflare_logger_backend,
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

config :phoenix, :filter_parameters, ["apikey"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
