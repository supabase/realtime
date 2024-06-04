import Config

config :logflare_logger_backend,
  url: System.get_env("LOGFLARE_LOGGER_BACKEND_URL", "https://api.logflare.app")

app_name = System.get_env("FLY_APP_NAME", "")
default_db_host = System.get_env("DB_HOST", "localhost")
username = System.get_env("DB_USER", "postgres")
password = System.get_env("DB_PASSWORD", "postgres")
database = System.get_env("DB_NAME", "postgres")
port = System.get_env("DB_PORT", "5432")
slot_name_suffix = System.get_env("SLOT_NAME_SUFFIX")

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  if app_name == "" do
    raise "APP_NAME not available"
  end

  config :realtime, RealtimeWeb.Endpoint,
    server: true,
    url: [host: "#{app_name}.fly.dev", port: 80],
    http: [
      port: String.to_integer(System.get_env("PORT") || "4000"),
      protocol_options: [
        max_header_value_length: String.to_integer(System.get_env("MAX_HEADER_LENGTH") || "4096")
      ],
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
end

if config_env() != :test do
  platform = if System.get_env("AWS_EXECUTION_ENV") == "AWS_ECS_FARGATE", do: :aws, else: :fly

  config :realtime,
    secure_channels: System.get_env("SECURE_CHANNELS", "true") == "true",
    jwt_claim_validators: System.get_env("JWT_CLAIM_VALIDATORS", "{}"),
    api_jwt_secret: System.get_env("API_JWT_SECRET"),
    api_blocklist: System.get_env("API_TOKEN_BLOCKLIST", "") |> String.split(","),
    metrics_blocklist: System.get_env("METRICS_TOKEN_BLOCKLIST", "") |> String.split(","),
    metrics_jwt_secret: System.get_env("METRICS_JWT_SECRET"),
    db_enc_key: System.get_env("DB_ENC_KEY"),
    region: System.get_env("FLY_REGION") || System.get_env("REGION"),
    fly_alloc_id: System.get_env("FLY_ALLOC_ID", ""),
    prom_poll_rate: System.get_env("PROM_POLL_RATE", "5000") |> String.to_integer(),
    platform: platform,
    slot_name_suffix: slot_name_suffix

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
    Realtime.Repo.Replica.SJC => System.get_env("DB_HOST_REPLICA_SJC", default_db_host),
    Realtime.Repo.Replica.Singapore => System.get_env("DB_HOST_REPLICA_SIN", default_db_host),
    Realtime.Repo.Replica.London => System.get_env("DB_HOST_REPLICA_FRA", default_db_host),
    Realtime.Repo.Replica.NorthVirginia => System.get_env("DB_HOST_REPLICA_IAD", default_db_host),
    Realtime.Repo.Replica.Oregon => System.get_env("DB_HOST_REPLICA_SJC", default_db_host),
    Realtime.Repo.Replica.SanJose => System.get_env("DB_HOST_REPLICA_SJC", default_db_host),
    Realtime.Repo.Replica.Local => default_db_host
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

default_cluster_strategy =
  config_env()
  |> case do
    :prod -> "DNS"
    _ -> "EPMD"
  end

cluster_topologies =
  System.get_env("CLUSTER_STRATEGIES", default_cluster_strategy)
  |> String.upcase()
  |> String.split(",")
  |> Enum.reduce([], fn strategy, acc ->
    strategy
    |> String.trim()
    |> case do
      "DNS" ->
        [
          fly6pn: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [
              polling_interval: 5_000,
              query: System.get_env("DNS_NODES"),
              node_basename: app_name
            ]
          ]
        ] ++ acc

      "POSTGRES" ->
        version = "#{Application.spec(:realtime)[:vsn]}" |> String.replace(".", "_")

        [
          postgres: [
            strategy: Realtime.Cluster.Strategy.Postgres,
            config: [
              hostname: default_db_host,
              username: username,
              password: password,
              database: database,
              port: port,
              parameters: [
                application_name: "cluster_node_#{node()}"
              ],
              heartbeat_interval: 5_000,
              node_timeout: 15_000,
              channel_name:
                System.get_env("POSTGRES_CLUSTER_CHANNEL_NAME", "realtime_cluster_#{version}")
            ]
          ]
        ] ++ acc

      "EPMD" ->
        [
          dev: [
            strategy: Cluster.Strategy.Epmd,
            config: [
              hosts: [:"orange@127.0.0.1", :"pink@127.0.0.1"]
            ],
            connect: {:net_kernel, :connect_node, []},
            disconnect: {:net_kernel, :disconnect_node, []}
          ]
        ] ++ acc

      _ ->
        acc
    end
  end)

config :libcluster,
  debug: false,
  topologies: cluster_topologies

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
