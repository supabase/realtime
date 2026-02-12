import Config

partition = System.get_env("MIX_TEST_PARTITION")

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
    database: "realtime_test#{partition}",
    hostname: "127.0.0.1",
    pool: Ecto.Adapters.SQL.Sandbox
end

http_port = if partition, do: 4002 + String.to_integer(partition), else: 4002

config :realtime, RealtimeWeb.Endpoint,
  http: [port: http_port],
  server: true

# that's what config/runtime.exs expects to see as region
System.put_env("REGION", "us-east-1")

config :realtime,
  regional_broadcasting: true,
  region: "us-east-1",
  db_enc_key: "1234567890123456",
  jwt_claim_validators: System.get_env("JWT_CLAIM_VALIDATORS", "{}"),
  api_jwt_secret: System.get_env("API_JWT_SECRET", "secret"),
  metrics_jwt_secret: "test",
  prom_poll_rate: 5_000,
  request_id_baggage_key: "sb-request-id",
  node_balance_uptime_threshold_in_ms: 999_999_999_999,
  max_gen_rpc_clients: 5

# Print nothing during tests unless captured or a test failure happens
config :logger,
  backends: [],
  level: :info

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:error_code, :request_id, :project, :external_id, :application_name, :sub, :iss, :exp]

config :opentelemetry,
  span_processor: :simple,
  traces_exporter: :none,
  processors: [{:otel_simple_processor, %{}}]

# Using different ports so that a remote node during test can connect using the same local network
# See Clustered module
gen_rpc_offset = if partition, do: String.to_integer(partition) * 10, else: 0

config :gen_rpc,
  tcp_server_port: 5969 + gen_rpc_offset,
  tcp_client_port: 5970 + gen_rpc_offset,
  connect_timeout: 500
