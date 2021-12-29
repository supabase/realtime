import Config

config :realtime,
  secure_channels: false,
  # ecto_repos: [RLS.Repo],
  publications: "[\"supabase_realtime\"]"

config :realtime, Realtime.RLS.Repo,
  database: "realtime_test#{System.get_env("MIX_TEST_PARTITION")}",
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
  log: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :realtime, RealtimeWeb.Endpoint,
  http: [port: 4002],
  server: false

config :joken,
  current_time_adapter: RealtimeWeb.Joken.CurrentTime.Mock

# Print only warnings and errors during test
config :logger, level: :warn
