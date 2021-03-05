defmodule Realtime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger, warn: false

  defmodule JwtSecretError, do: defexception([:message])
  defmodule JwtClaimValidatorsError, do: defexception([:message])

  def start(_type, _args) do
    # Hostname must be a char list for some reason
    # Use this var to convert to sigil at connection
    host = Application.fetch_env!(:realtime, :db_host)

    # Use a named replication slot if you want realtime to pickup from where
    # it left after a restart because of, for example, a crash.
    # This will always be converted to lower-case.
    # You can get a list of active replication slots with
    # `select * from pg_replication_slots`
    slot_name = Application.get_env(:realtime, :slot_name)

    epgsql_params = %{
      host: ~c(#{host}),
      username: Application.fetch_env!(:realtime, :db_user),
      database: Application.fetch_env!(:realtime, :db_name),
      password: Application.fetch_env!(:realtime, :db_password),
      port: Application.fetch_env!(:realtime, :db_port),
      ssl: Application.fetch_env!(:realtime, :db_ssl)
    }

    configuration_file = Application.fetch_env!(:realtime, :configuration_file)

    if Application.fetch_env!(:realtime, :secure_channels) do
      if Application.fetch_env!(:realtime, :jwt_secret) == "" do
        raise JwtSecretError, message: "JWT secret is missing"
      end

      case Application.fetch_env!(:realtime, :jwt_claim_validators) |> Jason.decode() do
        {:ok, claims} when is_map(claims) ->
          Application.put_env(:realtime, :jwt_claim_validators, claims)

        _ ->
          raise JwtClaimValidatorsError,
            message: "JWT claim validators is not a valid JSON object"
      end
    end

    # List all child processes to be supervised
    children = [
      # Start the endpoint when the application starts
      RealtimeWeb.Endpoint,
      {
        Phoenix.PubSub,
        name: Realtime.PubSub, adapter: Phoenix.PubSub.PG2
      },
      {
        Realtime.ConfigurationManager,
        filename: configuration_file
      },
      {
        Realtime.DatabaseReplicationSupervisor,
        # You can provide a different WAL position if desired, or default to
        # allowing Postgres to send you what it thinks you need
        epgsql_params: epgsql_params,
        publications: ["supabase_realtime"],
        slot_name: slot_name,
        wal_position: {"0", "0"}
      }
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    RealtimeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
