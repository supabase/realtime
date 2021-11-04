use Mix.Config

config :realtime,
  secure_channels: false,
  ecto_repos: [RLS.Repo],
  publications: "[\"supabase_realtime\"]"

config :realtime, Realtime.RLS.Repo,
  database: "postgres",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 5432,
  pool_size: 1,
  # socket_options: [db_ip_version],
  parameters: [application_name: "realtime_rls"],
  backoff_type: :rand_exp,
  backoff_min: 100,
  backoff_max: 120_000,
  log: false,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :realtime, RealtimeWeb.Endpoint,
  http: [port: 4002],
  server: false

config :joken,
  current_time_adapter: RealtimeWeb.Joken.CurrentTime.Mock

# Print only warnings and errors during test
config :logger, level: :warn
