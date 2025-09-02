import Config

defmodule Env do
  def get_integer(env, default) do
    value = System.get_env(env)
    if value, do: String.to_integer(value), else: default
  end

  def get_charlist(env, default) do
    value = System.get_env(env)
    if value, do: String.to_charlist(value), else: default
  end

  def get_boolean(env, default) do
    value = System.get_env(env)
    if value, do: String.to_existing_atom(value), else: default
  end
end

app_name = System.get_env("APP_NAME", "")

# Setup Database
default_db_host = System.get_env("DB_HOST", "127.0.0.1")
username = System.get_env("DB_USER", "postgres")
password = System.get_env("DB_PASSWORD", "postgres")
database = System.get_env("DB_NAME", "postgres")
port = System.get_env("DB_PORT", "5432")
db_version = System.get_env("DB_IP_VERSION")
slot_name_suffix = System.get_env("SLOT_NAME_SUFFIX")
db_ssl_enabled? = Env.get_boolean("DB_SSL", false)
db_ssl_ca_cert = System.get_env("DB_SSL_CA_CERT")
queue_target = Env.get_integer("DB_QUEUE_TARGET", 5000)
queue_interval = Env.get_integer("DB_QUEUE_INTERVAL", 5000)
pool_size = Env.get_integer("DB_POOL_SIZE", 5)

after_connect_query_args =
  case System.get_env("DB_AFTER_CONNECT_QUERY") do
    nil -> nil
    query -> {Postgrex, :query!, [query, []]}
  end

ssl_opts =
  cond do
    db_ssl_enabled? and is_binary(db_ssl_ca_cert) -> [cacertfile: db_ssl_ca_cert]
    db_ssl_enabled? -> [verify: :verify_none]
    true -> false
  end

tenant_cache_expiration = Env.get_integer("TENANT_CACHE_EXPIRATION_IN_MS", :timer.seconds(30))
migration_partition_slots = Env.get_integer("MIGRATION_PARTITION_SLOTS", System.schedulers_online() * 2)
connect_partition_slots = Env.get_integer("CONNECT_PARTITION_SLOTS", System.schedulers_online() * 2)
metrics_cleaner_schedule_timer_in_ms = Env.get_integer("METRICS_CLEANER_SCHEDULE_TIMER_IN_MS", :timer.minutes(30))
metrics_rpc_timeout_in_ms = Env.get_integer("METRICS_RPC_TIMEOUT_IN_MS", :timer.seconds(15))
rebalance_check_interval_in_ms = Env.get_integer("REBALANCE_CHECK_INTERVAL_IN_MS", :timer.minutes(10))
tenant_max_bytes_per_second = Env.get_integer("TENANT_MAX_BYTES_PER_SECOND", 100_000)
tenant_max_channels_per_client = Env.get_integer("TENANT_MAX_CHANNELS_PER_CLIENT", 100)
tenant_max_concurrent_users = Env.get_integer("TENANT_MAX_CONCURRENT_USERS", 200)
tenant_max_events_per_second = Env.get_integer("TENANT_MAX_EVENTS_PER_SECOND", 100)
tenant_max_joins_per_second = Env.get_integer("TENANT_MAX_JOINS_PER_SECOND", 100)
rpc_timeout = Env.get_integer("RPC_TIMEOUT", :timer.seconds(30))
max_gen_rpc_clients = Env.get_integer("MAX_GEN_RPC_CLIENTS", 5)
run_janitor? = Env.get_boolean("RUN_JANITOR", false)
janitor_schedule_randomize = Env.get_boolean("JANITOR_SCHEDULE_RANDOMIZE", true)
janitor_max_children = Env.get_integer("JANITOR_MAX_CHILDREN", 5)
janitor_chunk_size = Env.get_integer("JANITOR_CHUNK_SIZE", 10)
janitor_run_after_in_ms = Env.get_integer("JANITOR_RUN_AFTER_IN_MS", :timer.minutes(10))
janitor_children_timeout = Env.get_integer("JANITOR_CHILDREN_TIMEOUT", :timer.seconds(5))
janitor_schedule_timer = Env.get_integer("JANITOR_SCHEDULE_TIMER_IN_MS", :timer.hours(4))
platform = if System.get_env("AWS_EXECUTION_ENV") == "AWS_ECS_FARGATE", do: :aws, else: :fly

no_channel_timeout_in_ms =
  if config_env() == :test,
    do: :timer.seconds(3),
    else: Env.get_integer("NO_CHANNEL_TIMEOUT_IN_MS", :timer.minutes(10))

if !(db_version in [nil, "ipv6", "ipv4"]),
  do: raise("Invalid IP version, please set either ipv6 or ipv4")

socket_options =
  cond do
    db_version == "ipv6" ->
      [:inet6]

    db_version == "ipv4" ->
      [:inet]

    true ->
      case Realtime.Database.detect_ip_version(default_db_host) do
        {:ok, ip_version} -> [ip_version]
        {:error, reason} -> raise "Failed to detect IP version for DB_HOST: #{reason}"
      end
  end

config :realtime, Realtime.Repo,
  hostname: default_db_host,
  username: username,
  password: password,
  database: database,
  port: port,
  pool_size: pool_size,
  queue_target: queue_target,
  queue_interval: queue_interval,
  parameters: [application_name: "supabase_mt_realtime"],
  after_connect: after_connect_query_args,
  socket_options: socket_options,
  ssl: ssl_opts

config :realtime,
  migration_partition_slots: migration_partition_slots,
  connect_partition_slots: connect_partition_slots,
  rebalance_check_interval_in_ms: rebalance_check_interval_in_ms,
  tenant_max_bytes_per_second: tenant_max_bytes_per_second,
  tenant_max_channels_per_client: tenant_max_channels_per_client,
  tenant_max_concurrent_users: tenant_max_concurrent_users,
  tenant_max_events_per_second: tenant_max_events_per_second,
  tenant_max_joins_per_second: tenant_max_joins_per_second,
  metrics_cleaner_schedule_timer_in_ms: metrics_cleaner_schedule_timer_in_ms,
  metrics_rpc_timeout: metrics_rpc_timeout_in_ms,
  tenant_cache_expiration: tenant_cache_expiration,
  rpc_timeout: rpc_timeout,
  max_gen_rpc_clients: max_gen_rpc_clients,
  no_channel_timeout_in_ms: no_channel_timeout_in_ms,
  platform: platform

if config_env() != :test && run_janitor? do
  config :realtime,
    run_janitor: true,
    janitor_schedule_randomize: janitor_schedule_randomize,
    janitor_max_children: janitor_max_children,
    janitor_chunk_size: janitor_chunk_size,
    janitor_run_after_in_ms: janitor_run_after_in_ms,
    janitor_children_timeout: janitor_children_timeout,
    janitor_schedule_timer: janitor_schedule_timer
end

default_cluster_strategy =
  case config_env() do
    :prod -> "POSTGRES"
    _ -> "EPMD"
  end

cluster_topologies =
  System.get_env("CLUSTER_STRATEGIES", default_cluster_strategy)
  |> String.upcase()
  |> String.split(",")
  |> Enum.reduce([], fn strategy, acc ->
    strategy
    |> String.trim()
    |> then(fn
      "DNS" ->
        [
          dns: [
            strategy: Cluster.Strategy.DNSPoll,
            config: [polling_interval: 5_000, query: System.get_env("DNS_NODES"), node_basename: app_name]
          ]
        ] ++ acc

      "POSTGRES" ->
        [
          postgres: [
            strategy: LibclusterPostgres.Strategy,
            config: [
              hostname: default_db_host,
              username: username,
              password: password,
              database: database,
              port: port,
              parameters: [application_name: "cluster_node_#{node()}"],
              socket_options: socket_options,
              ssl: ssl_opts,
              heartbeat_interval: 5_000
            ]
          ]
        ] ++ acc

      "EPMD" ->
        [
          dev: [
            strategy: Cluster.Strategy.Epmd,
            config: [hosts: [:"orange@127.0.0.1", :"pink@127.0.0.1"]],
            connect: {:net_kernel, :connect_node, []},
            disconnect: {:net_kernel, :disconnect_node, []}
          ]
        ] ++ acc

      _ ->
        acc
    end)
  end)

# Setup Logging

if System.get_env("LOGS_ENGINE") == "logflare" do
  config :logflare_logger_backend, url: System.get_env("LOGFLARE_LOGGER_BACKEND_URL", "https://api.logflare.app")

  if !System.get_env("LOGFLARE_API_KEY") or !System.get_env("LOGFLARE_SOURCE_ID") do
    raise """
    Environment variable LOGFLARE_API_KEY or LOGFLARE_SOURCE_ID is missing.
    Check those variables or choose another LOGS_ENGINE.
    """
  end

  config :logger,
    sync_threshold: 6_000,
    discard_threshold: 6_000,
    backends: [LogflareLogger.HttpBackend]
end

# Setup production and development environments
if config_env() != :test do
  gen_rpc_socket_ip = System.get_env("GEN_RPC_SOCKET_IP", "0.0.0.0") |> to_charlist()

  gen_rpc_ssl_server_port = System.get_env("GEN_RPC_SSL_SERVER_PORT")

  gen_rpc_ssl_server_port =
    if gen_rpc_ssl_server_port do
      String.to_integer(gen_rpc_ssl_server_port)
    end

  gen_rpc_default_driver = if gen_rpc_ssl_server_port, do: :ssl, else: :tcp

  if gen_rpc_default_driver == :ssl do
    gen_rpc_ssl_opts = [
      certfile: System.fetch_env!("GEN_RPC_CERTFILE"),
      keyfile: System.fetch_env!("GEN_RPC_KEYFILE"),
      cacertfile: System.fetch_env!("GEN_RPC_CACERTFILE")
    ]

    config :gen_rpc,
      ssl_server_port: gen_rpc_ssl_server_port,
      ssl_client_port: System.get_env("GEN_RPC_SSL_CLIENT_PORT", "6369") |> String.to_integer(),
      ssl_client_options: gen_rpc_ssl_opts,
      ssl_server_options: gen_rpc_ssl_opts,
      tcp_server_port: false,
      tcp_client_port: false
  else
    config :gen_rpc,
      ssl_server_port: false,
      ssl_client_port: false,
      tcp_server_port: System.get_env("GEN_RPC_TCP_SERVER_PORT", "5369") |> String.to_integer(),
      tcp_client_port: System.get_env("GEN_RPC_TCP_CLIENT_PORT", "5369") |> String.to_integer()
  end

  case :inet.parse_address(gen_rpc_socket_ip) do
    {:ok, address} ->
      config :gen_rpc,
        default_client_driver: gen_rpc_default_driver,
        connect_timeout: System.get_env("GEN_RPC_CONNECT_TIMEOUT_IN_MS", "10000") |> String.to_integer(),
        send_timeout: System.get_env("GEN_RPC_SEND_TIMEOUT_IN_MS", "10000") |> String.to_integer(),
        ipv6_only: System.get_env("GEN_RPC_IPV6_ONLY", "false") == "true",
        socket_ip: address,
        max_batch_size: System.get_env("GEN_RPC_MAX_BATCH_SIZE", "0") |> String.to_integer(),
        compress: System.get_env("GEN_RPC_COMPRESS", "0") |> String.to_integer(),
        compression_threshold: System.get_env("GEN_RPC_COMPRESSION_THRESHOLD_IN_BYTES", "1000") |> String.to_integer()

    _ ->
      raise """
      Environment variable GEN_RPC_SOCKET_IP is not a valid IP Address
      Most likely it should be "0.0.0.0" (ipv4) or "::" (ipv6) to bind to all interfaces
      """
  end

  config :logger, level: System.get_env("LOG_LEVEL", "info") |> String.to_existing_atom()

  config :realtime,
    request_id_baggage_key: System.get_env("REQUEST_ID_BAGGAGE_KEY", "request-id"),
    jwt_claim_validators: System.get_env("JWT_CLAIM_VALIDATORS", "{}"),
    api_jwt_secret: System.get_env("API_JWT_SECRET"),
    api_blocklist: System.get_env("API_TOKEN_BLOCKLIST", "") |> String.split(","),
    metrics_blocklist: System.get_env("METRICS_TOKEN_BLOCKLIST", "") |> String.split(","),
    metrics_jwt_secret: System.get_env("METRICS_JWT_SECRET"),
    db_enc_key: System.get_env("DB_ENC_KEY"),
    region: System.get_env("REGION"),
    prom_poll_rate: Env.get_integer("PROM_POLL_RATE", 5000),
    slot_name_suffix: slot_name_suffix
end

# Setup Production

if config_env() == :prod do
  config :libcluster, debug: false, topologies: cluster_topologies
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")
  if app_name == "", do: raise("APP_NAME not available")

  config :realtime, RealtimeWeb.Endpoint,
    server: true,
    url: [host: "#{app_name}.supabase.co", port: 443],
    http: [
      compress: true,
      port: Env.get_integer("PORT", 4000),
      protocol_options: [
        max_header_value_length: Env.get_integer("MAX_HEADER_LENGTH", 4096)
      ],
      transport_options: [
        max_connections: Env.get_integer("MAX_CONNECTIONS", 1000),
        num_acceptors: Env.get_integer("NUM_ACCEPTORS", 100),
        socket_opts: [:inet6]
      ]
    ],
    check_origin: false,
    secret_key_base: secret_key_base

  alias Realtime.Repo.Replica

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
      ],
      socket_options: socket_options,
      ssl: ssl_opts
  end
end
