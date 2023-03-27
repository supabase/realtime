import Config

config :logflare_logger_backend,
  url: System.get_env("LOGFLARE_LOGGER_BACKEND_URL", "https://api.logflare.app")

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
      transport_options: [
        # max_connection is per connection supervisor
        # num_conns_sups defaults to num_acceptors
        # total conns accepted here is max_connections * num_acceptors
        # ref: https://ninenines.eu/docs/en/ranch/2.0/manual/ranch/
        max_connections: String.to_integer(System.get_env("MAX_CONNECTIONS") || "1000"),
        num_acceptors: String.to_integer(System.get_env("NUM_ACCEPTORS") || "100"),
        # IMPORTANT: support IPv6 addresses
        socket_opts: [:inet6]
      ]
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

if config_env() != :test do
  config :realtime,
    secure_channels: System.get_env("SECURE_CHANNELS", "true") == "true",
    jwt_claim_validators: System.get_env("JWT_CLAIM_VALIDATORS", "{}"),
    api_jwt_secret: System.get_env("API_JWT_SECRET"),
    metrics_jwt_secret: System.get_env("METRICS_JWT_SECRET"),
    db_enc_key: System.get_env("DB_ENC_KEY"),
    fly_region: System.get_env("FLY_REGION"),
    fly_alloc_id: System.get_env("FLY_ALLOC_ID"),
    prom_poll_rate: System.get_env("PROM_POLL_RATE", "5000") |> String.to_integer()

  default_db_host = System.get_env("DB_HOST", "localhost")
  username = System.get_env("DB_USER", "postgres")
  password = System.get_env("DB_PASSWORD", "postgres")
  database = System.get_env("DB_NAME", "postgres")
  port = System.get_env("DB_PORT", "5432")
  queue_target = System.get_env("DB_QUEUE_TARGET", "5000") |> String.to_integer()
  queue_interval = System.get_env("DB_QUEUE_INTERVAL", "5000") |> String.to_integer()

  after_connect_query_args =
    case System.get_env("DB_AFTER_CONNECT_QUERY") do
      nil -> nil
      query -> {Postgrex, :query!, [query, []]}
    end

  config :realtime, Realtime.Repo,
    hostname: default_db_host,
    username: username,
    password: password,
    database: database,
    port: port,
    pool_size: System.get_env("DB_POOL_SIZE", "5") |> String.to_integer(),
    queue_target: queue_target,
    queue_interval: queue_interval,
    parameters: [
      application_name: "supabase_mt_realtime"
    ],
    after_connect: after_connect_query_args

  replica_repos = %{
    Realtime.Repo.Replica.FRA => System.get_env("DB_HOST_REPLICA_FRA", default_db_host),
    Realtime.Repo.Replica.IAD => System.get_env("DB_HOST_REPLICA_IAD", default_db_host),
    Realtime.Repo.Replica.SIN => System.get_env("DB_HOST_REPLICA_SIN", default_db_host),
    Realtime.Repo.Replica.SJC => System.get_env("DB_HOST_REPLICA_SJC", default_db_host)
  }

  # username, password, database, and port must match primary credentials
  for {replica_repo, hostname} <- replica_repos do
    config :realtime, replica_repo,
      hostname: hostname,
      username: username,
      password: password,
      database: database,
      port: port,
      pool_size: System.get_env("DB_REPLICA_POOL_SIZE", "5") |> String.to_integer(),
      queue_target: queue_target,
      queue_interval: queue_interval,
      parameters: [
        application_name: "supabase_mt_realtime_ro"
      ]
  end
end

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
