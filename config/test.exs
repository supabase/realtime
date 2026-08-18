import Config

get_integer = fn env, default ->
  case System.get_env(env) do
    nil -> default
    value -> String.to_integer(value)
  end
end

partition = System.get_env("MIX_TEST_PARTITION")
db_port = get_integer.("DB_PORT", 5432)
db_name = System.get_env("TEST_DB_NAME", "realtime_test#{partition}")

for repo <- [
      Realtime.Repo,
      Realtime.Repo.Replica.FRA,
      Realtime.Repo.Replica.IAD,
      Realtime.Repo.Replica.SIN,
      Realtime.Repo.Replica.SJC,
      Realtime.Repo.Replica.Singapore,
      Realtime.Repo.Replica.London,
      Realtime.Repo.Replica.NorthVirginia,
      Realtime.Repo.Replica.Oregon,
      Realtime.Repo.Replica.SanJose
    ] do
  config :realtime, repo,
    username: "supabase_admin",
    password: "postgres",
    database: db_name,
    hostname: "127.0.0.1",
    port: db_port,
    pool: Ecto.Adapters.SQL.Sandbox
end

default_http_port = if partition, do: 4002 + String.to_integer(partition), else: 4002
http_port = get_integer.("TEST_PORT", default_http_port)

# Single-node test scopes have no peers to agree with, so they only reach
# :ready via the singleton-promotion timer. Keep it short so Muster.targets/3
# stops flooding almost immediately instead of after the 30s default.
config :realtime, muster_singleton_promotion_timeout_ms: 100

config :realtime, RealtimeWeb.Endpoint,
  http: [port: http_port],
  server: true

# that's what config/runtime.exs expects to see as region
System.put_env("REGION", "us-east-1")

config :realtime,
  region: "us-east-1",
  db_enc_key: "1234567890123456",
  db_enc_key_gcm: "12345678901234567890123456789012",
  db_enc_write_gcm: true,
  jwt_claim_validators: System.get_env("JWT_CLAIM_VALIDATORS", "{}"),
  api_jwt_secret: System.get_env("API_JWT_SECRET", "secret"),
  metrics_jwt_secret: "test",
  prom_poll_rate: 5_000,
  request_id_baggage_key: "sb-request-id",
  node_balance_uptime_threshold_in_ms: 999_999_999_999,
  connect_error_backoff_ms: 100,
  channel_error_backoff_ms: 100,
  connect_connection_ready_timeout: 2_000,
  max_gen_rpc_clients: 5,
  max_gen_rpc_call_clients: 1,
  metrics_pusher_req_options: [
    adapter: &Realtime.ReqTestRawAdapter.call(&1, Realtime.MetricsPusher)
  ]

# Print nothing during tests unless captured or a test failure happens
config :logger,
  default_handler: false,
  level: :info

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :error_code,
    :request_id,
    :project,
    :external_id,
    :application_name,
    :sub,
    :iss,
    :exp
  ]

config :opentelemetry,
  span_processor: :simple,
  traces_exporter: :none,
  processors: [{:otel_simple_processor, %{}}]

# Using different ports so that a remote node during test can connect using the same local network
# See Clustered module
gen_rpc_offset = if partition, do: String.to_integer(partition) * 10, else: 0

gen_rpc_tcp_server_port = get_integer.("TEST_GEN_RPC_TCP_SERVER_PORT", 5969 + gen_rpc_offset)
gen_rpc_tcp_client_port = get_integer.("TEST_GEN_RPC_TCP_CLIENT_PORT", 5970 + gen_rpc_offset)

config :gen_rpc,
  tcp_server_port: gen_rpc_tcp_server_port,
  tcp_client_port: gen_rpc_tcp_client_port,
  connect_timeout: 500

config :realtime, :dashboard_auth, :basic_auth
config :realtime, :dashboard_credentials, {"test_user", "test_password"}
