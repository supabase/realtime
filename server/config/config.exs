# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

# These defaults mirror the ones in releases.exs, remember not to change one
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
publications = System.get_env("PUBLICATIONS", "[\"supabase_realtime\"]")
slot_name = System.get_env("SLOT_NAME") || :temporary
configuration_file = System.get_env("CONFIGURATION_FILE") || nil

# Workflows database connection settings
workflows_db_host = System.get_env("WORKFLOWS_DB_HOST", db_host)
workflows_db_port = String.to_integer(System.get_env("WORKFLOWS_DB_PORT", inspect db_port))
workflows_db_name = System.get_env("WORKFLOWS_DB_NAME", db_name)
workflows_db_user = System.get_env("WORKFLOWS_DB_USER", db_user)
workflows_db_password = System.get_env("WORKFLOWS_DB_PASSWORD", db_password)
workflows_db_schema = System.get_env("WORKFLOWS_DB_SCHEMA", "public")
workflows_db_ssl = System.get_env("WORKFLOWS_DB_SSL", inspect db_ssl) === "true"

# Channels are not secured by default in development and
# are secured by default in production.
secure_channels = System.get_env("SECURE_CHANNELS", "true") != "false"

# Supports HS algorithm octet keys
# e.g. "95x0oR8jq9unl9pOIx"
jwt_secret = System.get_env("JWT_SECRET", "")

# Every JWT's claims will be compared (equality checks) to the expected
# claims set in the JSON object.
# e.g.
# Set JWT_CLAIM_VALIDATORS="{'iss': 'Issuer', 'nbf': 1610078130}"
# Then JWT's "iss" value must equal "Issuer" and "nbf" value
# must equal 1610078130.
jwt_claim_validators = System.get_env("JWT_CLAIM_VALIDATORS", "{}")

# The secret key base to built the cookie signing/encryption key.
session_secret_key_base = System.get_env("SESSION_SECRET_KEY_BASE", "Kyvjr42ZvLcY6yzZ7vmRUniE7Bta9tpknEAvpxtaYOa/marmeI1jsqxhIKeu6V51")

# Set Cowboy server idle_timeout value. Set to a larger number, in milliseconds, or "infinity". Default is 60000 (1 minute).
socket_timeout = case System.get_env("SOCKET_TIMEOUT") do
  "infinity" -> :infinity
  timeout -> try do
    String.to_integer(timeout)
  rescue
    ArgumentError -> 60_000
  end
end

config :realtime,
  app_hostname: app_hostname,
  app_port: app_port,
  db_host: db_host,
  db_port: db_port,
  db_name: db_name,
  db_user: db_user,
  db_password: db_password,
  db_ssl: db_ssl,
  publications: publications,
  slot_name: slot_name,
  configuration_file: configuration_file,
  workflows_db_host: workflows_db_host,
  workflows_db_port: workflows_db_port,
  workflows_db_name: workflows_db_name,
  workflows_db_user: workflows_db_user,
  workflows_db_password: workflows_db_password,
  workflows_db_schema: workflows_db_schema,
  workflows_db_ssl: workflows_db_ssl,
  secure_channels: secure_channels,
  jwt_secret: jwt_secret,
  jwt_claim_validators: jwt_claim_validators,
  socket_timeout: socket_timeout,
  ecto_repos: [Realtime.Repo]

# Configures the endpoint
config :realtime, RealtimeWeb.Endpoint,
  url: [host: "localhost"],
  render_errors: [view: RealtimeWeb.ErrorView, accepts: ~w(html json)],
  pubsub_server: Realtime.PubSub,
  secret_key_base: session_secret_key_base

config :realtime, Realtime.Repo,
  hostname: workflows_db_host,
  port: workflows_db_port,
  database: workflows_db_name,
  username: workflows_db_user,
  password: workflows_db_password

config :realtime, Oban,
  repo: Realtime.Repo,
  plugins: [Oban.Plugins.Pruner],
  queues: [interpreter: 10]

config :realtime, Realtime.EventStore.Store,
  # column_data_type: "jsonb",
  # serializer: EventStore.JsonbSerializer,
  # Needed to serialize erlang tuples used in event scope
  # types: EventStore.PostgresTypes,
  # TODO: use term serializer for now. Switch to JsonbSerializer before release.
  serializer: EventStore.TermSerializer,
  hostname: workflows_db_host,
  port: workflows_db_port,
  database: workflows_db_name,
  username: workflows_db_user,
  password: workflows_db_password,
  # TODO: since event_store uses the same name as ecto for the migration table,
  # we need to use a separate schema. Either make this one available or solve
  # the problem at the root (rename migration tables not to clash).
  schema: "event_store"

config :realtime, event_stores: [Realtime.EventStore.Store]

config :realtime, :workflows,
  resource_handlers: [Realtime.Resource.Http]

# Configures Elixir's Logger
config :logger, :console,
  format: "$date $time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env()}.exs"
