defmodule Extensions.PostgresCdcRls.Migrations do
  @moduledoc false
  use GenServer

  alias Realtime.Repo
  alias Realtime.Helpers, as: H

  @spec start_link(GenServer.options()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  ## Callbacks

  @impl true
  def init(args) do
    # applying tenant's migrations
    apply_migrations(args)
    # need try to stop this PID
    {:ok, %{}}
    # {:ok, %{}, {:continue, :stop}}
  end

  @impl true
  def handle_continue(:stop, %{}) do
    {:stop, :normal, %{}}
  end

  @spec apply_migrations(map()) :: [integer()]
  defp apply_migrations(args) do
    {host, port, name, user, pass} =
      H.decrypt_creds(
        args["db_host"],
        args["db_port"],
        args["db_name"],
        args["db_user"],
        args["db_password"]
      )

    Repo.with_dynamic_repo(
      [
        hostname: host,
        port: port,
        database: name,
        password: pass,
        username: user,
        pool_size: 2,
        socket_options: args["db_socket_opts"]
      ],
      fn repo ->
        Ecto.Migrator.run(
          Repo,
          [Ecto.Migrator.migrations_path(Repo, "postgres/migrations")],
          :up,
          all: true,
          prefix: "realtime",
          dynamic_repo: repo
        )
      end
    )
  end
end
