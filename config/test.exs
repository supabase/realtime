import Config

get_integer = fn env, default ->
  case System.get_env(env) do
    nil -> default
    value -> String.to_integer(value)
  end
end

port_free? = fn port ->
  case :gen_tcp.listen(port, [:inet, ip: {0, 0, 0, 0}, reuseaddr: true, active: false]) do
    {:ok, socket} -> :gen_tcp.close(socket) == :ok
    {:error, _reason} -> false
  end
end

first_http_port = 4002

http_port =
  get_integer.("TEST_PORT", nil) || Enum.find(first_http_port..4999, port_free?) ||
    raise "no free port in #{first_http_port}..4999"

# The endpoint port is the only one bound for a whole run, so taking it is what makes a run
# unique. Every other port sits the same distance from its own default: peer ports are bound
# only while a clustered test runs, so scanning for those would let two runs claim the same ones.
offset = http_port - first_http_port

# Node names, kept short: they end up inside inspected maps in logs that tests assert on.
node_suffix =
  case offset do
    0 -> ""
    _ -> "_#{http_port}"
  end

# Names this run's database and containers. RUN_TAG labels a session — "pr_1234",
# "fix_something" — and otherwise the endpoint port does, which also lets a later run tell
# whether the run that left something behind is gone.
run_tag =
  case {offset, System.get_env("RUN_TAG")} do
    {0, nil} -> ""
    {_, nil} -> "_#{http_port}"
    {_, name} -> "_#{name}"
  end

partition = System.get_env("MIX_TEST_PARTITION")
db_port = get_integer.("DB_PORT", 5432)
db_name = System.get_env("TEST_DB_NAME", "realtime_test#{partition}#{run_tag}")

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

# 16 ports each, one per peer in TestEnv's slots, in bands of their own so no run's peers can
# land on another run's endpoint or gen_rpc port.
peer_http_base = get_integer.("TEST_PEER_PORT_BASE", nil) || 10_000 + offset * 16
peer_gen_rpc_base = get_integer.("TEST_PEER_GEN_RPC_PORT_BASE", nil) || 26_000 + offset * 16

config :realtime,
  test_run_tag: run_tag,
  test_node_suffix: node_suffix,
  test_http_port: http_port,
  test_peer_http_base: peer_http_base,
  test_peer_gen_rpc_base: peer_gen_rpc_base

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

# Adjacent server and client ports: Clustered swaps them so a peer can connect back.
gen_rpc_base = get_integer.("TEST_GEN_RPC_TCP_SERVER_PORT", nil) || 5969 + offset * 2

config :gen_rpc,
  tcp_server_port: gen_rpc_base,
  tcp_client_port: get_integer.("TEST_GEN_RPC_TCP_CLIENT_PORT", gen_rpc_base + 1),
  connect_timeout: 500

config :realtime, :dashboard_auth, :basic_auth
config :realtime, :dashboard_credentials, {"test_user", "test_password"}
