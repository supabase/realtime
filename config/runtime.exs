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

  config :multiplayer, MultiplayerWeb.Endpoint,
    server: true,
    url: [host: "#{app_name}.fly.dev", port: 80],
    http: [
      port: String.to_integer(System.get_env("PORT") || "4000"),
      # IMPORTANT: support IPv6 addresses
      transport_options: [socket_opts: [:inet6]]
    ],
    check_origin: false,
    secret_key_base: secret_key_base

  config :multiplayer, Multiplayer.Repo,
    username: System.get_env("DB_USER"),
    password: System.get_env("DB_PASSWORD"),
    database: System.get_env("DB_NAME"),
    hostname: System.get_env("DB_HOST"),
    port: System.get_env("DB_PORT"),
    show_sensitive_data_on_connection_error: true,
    pool_size: 3

  config :multiplayer,
    ecto_repos: [Multiplayer.Repo],
    secure_channels: System.get_env("SECURE_CHANNELS", "true") == "true",
    jwt_claim_validators: System.get_env("JWT_CLAIM_VALIDATORS", "{}")

  config :libcluster,
    debug: true,
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
