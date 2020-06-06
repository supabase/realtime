import Config

# These defaults mirror the ones in config.exs, remember not to change one
# without changing the other.
app_hostname = System.get_env("HOSTNAME", "localhost")
app_port = String.to_integer(System.get_env("PORT", "4000"))
db_host = System.get_env("DB_HOST", "localhost")
db_port = String.to_integer(System.get_env("DB_PORT", "5432"))
db_name = System.get_env("DB_NAME", "postgres")
db_user = System.get_env("DB_USER", "postgres")
db_password = System.get_env("DB_PASSWORD", "postgres")
# HACK: There's probably a better way to set boolean from env
db_ssl = System.get_env("DB_SSL", "true") === "true"
slot_name = System.get_env("SLOT_NAME") || :temporary
configuration_file = System.get_env("CONFIGURATION_FILE")

config :realtime,
  app_hostname: app_hostname,
  app_port: app_port,
  db_host: db_host,
  db_port: db_port,
  db_name: db_name,
  db_user: db_user,
  db_password: db_password,
  db_ssl: db_ssl,
  slot_name: slot_name,
  configuration_file: configuration_file

secret_key_base =
  System.get_env("SECRET_KEY_BASE") ||
    raise """
    environment variable SECRET_KEY_BASE is missing.
    You can generate one by calling: mix phx.gen.secret
    """

config :realtime, RealtimeWeb.Endpoint,
  http: [:inet6, port: app_port],
  secret_key_base: secret_key_base
