defmodule Realtime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger, warn: false

  alias Realtime.{
    ConfigurationManager,
    Helpers,
    PubSub,
    ReplicationStreamSupervisor,
    RLS,
    SubscriptionManager
  }

  alias RealtimeWeb.Endpoint

  defmodule JwtSecretError, do: defexception([:message])
  defmodule JwtClaimValidatorsError, do: defexception([:message])
  defmodule ReplicationModeError, do: defexception([:message])

  def start(_type, _args) do
    # Use a named replication slot if you want realtime to pickup from where
    # it left after a restart because of, for example, a crash.
    # This will always be converted to lower-case.
    # You can get a list of active replication slots with
    # `select * from pg_replication_slots`
    # and delete with
    # `select pg_drop_replication_slot('some_slot_name')`
    slot_name = Application.get_env(:realtime, :slot_name)
    publications = Application.get_env(:realtime, :publications) |> Jason.decode!()
    configuration_file = Application.fetch_env!(:realtime, :configuration_file)

    replication_mode = Application.fetch_env!(:realtime, :replication_mode)

    replication_children =
      case replication_mode do
        "STREAM" ->
          # Hostname must be a char list for some reason
          # Use this var to convert to sigil at connection
          host = Application.fetch_env!(:realtime, :db_host)

          max_replication_lag_in_mb =
            Application.fetch_env!(:realtime, :max_replication_lag_in_mb)

          epgsql_params = %{
            host: ~c(#{host}),
            username: Application.fetch_env!(:realtime, :db_user),
            database: Application.fetch_env!(:realtime, :db_name),
            password: Application.fetch_env!(:realtime, :db_password),
            port: Application.fetch_env!(:realtime, :db_port),
            ssl: Application.fetch_env!(:realtime, :db_ssl),
            application_name: "realtime"
          }

          epgsql_params =
            with {:ok, ip_version} <- Application.fetch_env!(:realtime, :db_ip_version),
                 {:error, :einval} <- :inet.parse_address(epgsql_params.host) do
              # only add :tcp_opts to epgsql_params when ip_version is present and host
              # is not an IP address.
              Map.put(epgsql_params, :tcp_opts, [ip_version])
            else
              _ -> epgsql_params
            end

          [
            {
              ReplicationStreamSupervisor,
              # You can provide a different WAL position if desired, or default to
              # allowing Postgres to send you what it thinks you need
              epgsql_params: epgsql_params,
              publications: publications,
              slot_name: slot_name,
              wal_position: {"0", "0"},
              max_replication_lag_in_mb: max_replication_lag_in_mb
            }
          ]

        "RLS" ->
          [publication] = publications
          repo_opts = Application.fetch_env!(:realtime, RLS.Repo)

          [
            RLS.Repo,
            {
              RLS.ReplicationPoller,
              backoff_type: Keyword.fetch!(repo_opts, :backoff_type),
              backoff_min: Keyword.fetch!(repo_opts, :backoff_min),
              backoff_max: Keyword.fetch!(repo_opts, :backoff_max),
              replication_poll_interval:
                Application.fetch_env!(:realtime, :replication_poll_interval),
              publication: publication,
              slot_name: slot_name,
              temporary_slot: Application.fetch_env!(:realtime, :temporary_slot),
              max_record_bytes: Application.fetch_env!(:realtime, :max_record_bytes)
            }
          ]

        _ ->
          raise ReplicationModeError, message: "Replication mode is incorrect"
      end

    if Application.fetch_env!(:realtime, :secure_channels) and
         Application.fetch_env!(:realtime, :jwt_secret) == "" do
      raise JwtSecretError, message: "JWT secret is missing"
    end

    Application.fetch_env!(:realtime, :jwt_claim_validators)
    |> Jason.decode()
    |> case do
      {:ok, claims} when is_map(claims) ->
        Application.put_env(:realtime, :jwt_claim_validators, claims)

      _ ->
        raise JwtClaimValidatorsError,
          message: "JWT claim validators is not a valid JSON object"
    end

    def_headers = Application.fetch_env!(:realtime, :webhook_default_headers)

    headers =
      with {:ok, env_val} <- Application.fetch_env(:realtime, :webhook_headers),
           {:ok, decoded_headers} <- Helpers.env_kv_to_list(env_val, def_headers) do
        decoded_headers
      else
        _ -> def_headers
      end

    Application.put_env(:realtime, :webhook_headers, headers)

    essential_children = [
      Realtime.Metrics.PromEx,
      Realtime.Metrics.SocketMonitor,
      {
        Phoenix.PubSub,
        name: PubSub, adapter: Phoenix.PubSub.PG2
      },
      Endpoint,
      {
        SubscriptionManager,
        replication_mode: replication_mode,
        subscription_sync_interval: Application.fetch_env!(:realtime, :subscription_sync_interval)
      },
      {
        ConfigurationManager,
        filename: configuration_file
      }
    ]

    children = essential_children ++ replication_children

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    Endpoint.config_change(changed, removed)
    :ok
  end
end
