import Config

app_port = System.get_env("PORT") || 4000
app_hostname = System.get_env("HOSTNAME") || "localhost"
db_user = System.get_env("DB_USER") || "postgres"
db_password = System.get_env("DB_PASSWORD") || "postgres"
db_host = System.get_env("DB_HOST") || "localhost"
db_port = System.get_env("DB_PORT") || 5432
db_name = System.get_env("DB_NAME") || "postgres"
db_ssl = System.get_env("DB_SSL") || true

secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    raise """
    environment variable SECRET_KEY_BASE is missing.
    You can generate one by calling:
    export SECRET_KEY_BASE=`openssl rand -base64 48`
    """

config :realtime, RealtimeWeb.Endpoint,
  http: [:inet6, port: String.to_integer(app_port)],
  secret_key_base: secret_key_base

config :realtime,
  app_port: app_port

config :realtime,
  app_hostname: app_hostname
