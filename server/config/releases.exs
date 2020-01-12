import Config

app_port = System.fetch_env!("APP_PORT")
app_hostname = System.fetch_env!("APP_HOSTNAME")
db_user = System.fetch_env!("DB_USER")
db_password = System.fetch_env!("DB_PASSWORD")
db_host = System.fetch_env!("DB_HOST")
db_port = System.fetch_env!("DB_PORT")
db_name = System.fetch_env!("DB_NAME")

config :realtime, RealtimeWeb.Endpoint,
  http: [:inet6, port: String.to_integer(app_port)]

config :realtime,
  app_port: app_port

config :realtime,
  app_hostname: app_hostname
