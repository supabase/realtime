import Config

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  app_name =
    System.get_env("FLY_APP_NAME") ||
      raise "APP_NAME not available"

  config :realtime, RealtimeWeb.Endpoint,
    server: true,
    url: [host: "#{app_name}.fly.dev", port: 80],
    http: [
      port: String.to_integer(System.get_env("PORT") || "4000"),
      # IMPORTANT: support IPv6 addresses
      transport_options: [socket_opts: [:inet6]]
    ],
    check_origin: false,
    secret_key_base: secret_key_base

  config :libcluster,
    debug: false,
    topologies: [
      fly6pn: [
        strategy: Cluster.Strategy.DNSPoll,
        config: [
          polling_interval: 5_000,
          query: System.get_env("DNS_NODES"),
          node_basename: app_name
        ]
      ]
    ]
end

config :realtime, Realtime.Repo,
  username: System.get_env("DB_USER", "postgres"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  database: System.get_env("DB_NAME", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  port: System.get_env("DB_PORT", "5432"),
  show_sensitive_data_on_connection_error: true,
  pool_size: System.get_env("DB_POOL_SIZE", "5") |> String.to_integer(),
  prepare: :unnamed,
  queue_target: 5000,
  queue_interval: 5000

config :realtime,
  secure_channels: System.get_env("SECURE_CHANNELS", "true") == "true",
  jwt_claim_validators: System.get_env("JWT_CLAIM_VALIDATORS", "{}"),
  api_jwt_secret: System.get_env("API_JWT_SECRET")

if System.get_env("LOGS_ENGINE") == "logflare" do
  if !System.get_env("LOGFLARE_API_KEY") or !System.get_env("LOGFLARE_SOURCE_ID") do
    raise """
    Environment variable LOGFLARE_API_KEY or LOGFLARE_SOURCE_ID is missing.
    Check those variables or choose another LOGS_ENGINE.
    """
  end

  config :logger,
    backends: [LogflareLogger.HttpBackend]
end
