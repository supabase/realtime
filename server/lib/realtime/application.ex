defmodule Realtime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger, warn: false

  def start(_type, _args) do

    # Hostname must be a char list for some reason
    # Use this var to convert to sigil at connection
    host = System.get_env("DB_HOST") || 'localhost'
    port = System.get_env("DB_PORT") || "5432"
    {port_number, _} = :string.to_integer(to_charlist(port))
    epgsql_params = %{
      host: ~c(#{host}),
      username: System.get_env("DB_USER") || "postgres",
      database: System.get_env("DB_NAME") || "postgres",
      password: System.get_env("DB_PASSWORD") || "postgres",
      port: port_number,
      ssl: System.get_env("DB_SSL") || true
    }

    # List all child processes to be supervised
    children = [
      # Start the endpoint when the application starts
      RealtimeWeb.Endpoint,
      {
        Realtime.Replication,
        epgsql: epgsql_params,
        slot: :temporary, # :temporary is also supported if you don't want Postgres keeping track of what you've acknowledged
        wal_position: {"0", "0"}, # You can provide a different WAL position if desired, or default to allowing Postgres to send you what it thinks you need
        publications: ["supabase_realtime"]
      },
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Realtime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    RealtimeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
