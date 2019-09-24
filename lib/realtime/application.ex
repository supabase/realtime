defmodule Realtime.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  def start(_type, _args) do

    # Hostname must be a char list for some reason
    # Use this var to convert to sigil at connection
    host = System.get_env("POSTGRES_HOST") || 'localhost'
    port = System.get_env("POSTGRES_PORT") || 6543
    {port_number, _} = :string.to_integer(to_char_list(port))

    # List all child processes to be supervised
    children = [
      # Start the Ecto repository
      Realtime.Repo,
      # Start the endpoint when the application starts
      RealtimeWeb.Endpoint,
      # Starts a worker by calling: Realtime.Worker.start_link(arg)
      # {Realtime.Worker, arg},
      Supervisor.Spec.worker(
        Realtime.Notify, 
        ["db_changes", [name: Realtime.Notify]],
        restart: :permanent
      ),
      {
        Cainophile.Adapters.Postgres,
        register: Cainophile.RealtimeListener, # name this process will be registered globally as, for usage with Cainophile.Adapters.Postgres.subscribe/2
        epgsql: %{ # All epgsql options are supported here
          host: ~c(#{host}),
          username: System.get_env("POSTGRES_USER") || "postgres",
          database: System.get_env("POSTGRES_DB") || "postgres",
          password: System.get_env("POSTGRES_PASSWORD") || "postgres",
          port: port_number
        },
        slot: :temporary, # :temporary is also supported if you don't want Postgres keeping track of what you've acknowledged
        wal_position: {"0", "0"}, # You can provide a different WAL position if desired, or default to allowing Postgres to send you what it thinks you need
        publications: ["supabase_realtime"]
      },
      Supervisor.Spec.worker(
        Realtime.Replication, 
        ["supabase_realtime", [name: Realtime.Replication]],
        restart: :permanent
      ),
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
