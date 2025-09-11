import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
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
    username: "postgres",
    password: "postgres",
    database: "realtime_test",
    hostname: "127.0.0.1",
    pool: Ecto.Adapters.SQL.Sandbox
end

# Running server during tests to run integration tests
config :realtime, RealtimeWeb.Endpoint,
  http: [port: 4002],
  server: true

config :realtime,
  region: "us-east-1",
  db_enc_key: "1234567890123456",
  jwt_claim_validators: System.get_env("JWT_CLAIM_VALIDATORS", "{}"),
  api_jwt_secret: System.get_env("API_JWT_SECRET", "secret"),
  metrics_jwt_secret: "test",
  prom_poll_rate: 5_000,
  request_id_baggage_key: "sb-request-id"

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
config :gen_rpc,
  tcp_server_port: 5969,
  tcp_client_port: 5970
