defmodule Realtime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger, warn: false

  def start(_type, _args) do
    # Hostname must be a char list for some reason
    # Use this var to convert to sigil at connection
    host = Application.fetch_env!(:realtime, :db_host)
    port = Application.fetch_env!(:realtime, :db_port)
    # Use a named replication slot if you want realtime to pickup from where
    # it left after a restart because of, for example, a crash.
    # You can get a list of active replication slots with
    # `select * from pg_replication_slots`
    slot_name = Application.fetch_env!(:realtime, :slot_name)
    {port_number, _} = :string.to_integer(to_charlist(port))

    epgsql_params = %{
      host: ~c(#{host}),
      username: Application.fetch_env!(:realtime, :db_user),
      database: Application.fetch_env!(:realtime, :db_name),
      password: Application.fetch_env!(:realtime, :db_password),
      port: port_number,
      ssl: Application.fetch_env!(:realtime, :db_ssl)
    }

    configuration_file = Application.fetch_env!(:realtime, :configuration_file)

    # List all child processes to be supervised
    children = [
      # Start the endpoint when the application starts
      RealtimeWeb.Endpoint,
      {
        Realtime.Replication,
        # You can provide a different WAL position if desired, or default to allowing Postgres to send you what it thinks you need
        epgsql: epgsql_params,
        slot: slot_name,
        wal_position: {"0", "0"},
        publications: ["supabase_realtime"]
      },
      {
        Realtime.ConfigurationManager,
        filename: configuration_file
      },
      Realtime.SubscribersNotification,
      {
        Realtime.Connectors,
        config: nil
      },
      Realtime.WebhookConnector
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
