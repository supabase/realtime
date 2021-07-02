use Mix.Config


# We don't run a server during test. If one is required,
# you can enable the server option below.
config :multiplayer, MultiplayerWeb.Endpoint,
  http: [port: 4002],
  server: false

config :multiplayer,
  secure_channels: false

config :joken,
  current_time_adapter: MultiplayerWeb.Joken.CurrentTime.Mock

# Print only warnings and errors during test
config :logger, level: :warn
