import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :realtime, Realtime.Repo,
  username: "postgres",
  password: "postgres",
  database: "realtime_test",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :realtime, RealtimeWeb.Endpoint,
  http: [port: 4002],
  server: false

config :realtime,
  secure_channels: true,
  db_enc_key: "1234567890123456",
  jwt_claim_validators: System.get_env("JWT_CLAIM_VALIDATORS", "{}"),
  api_jwt_secret: System.get_env("API_JWT_SECRET")

config :joken,
  current_time_adapter: RealtimeWeb.Joken.CurrentTime.Mock

# Print only warnings and errors during test
config :logger, level: :warn
