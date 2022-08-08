import Config

if System.get_env("LOGFLARE_API_KEY") && System.get_env("LOGFLARE_SOURCE_ID") do
  config :logger,
    backends: [LogflareLogger.HttpBackend]
end
