use Mix.Config

config :realtime,
  secure_channels: false

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :realtime, RealtimeWeb.Endpoint,
  http: [port: 4002],
  server: false

config :realtime, Realtime.Repo,
       username: "postgres",
       password: "postgres",
       database: "realtime_test",
       hostname: "localhost",
       pool: Ecto.Adapters.SQL.Sandbox

config :joken,
  current_time_adapter: RealtimeWeb.Joken.CurrentTime.Mock

# Print only warnings and errors during test
config :logger, level: :warn
