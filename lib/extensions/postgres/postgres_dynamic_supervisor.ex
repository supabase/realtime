defmodule Extensions.Postgres.DynamicSupervisor do
  @moduledoc false
  use Supervisor

  import Realtime.Helpers, only: [decrypt_creds: 5]

  alias Realtime.Repo
  alias Extensions.Postgres
  alias Postgres.{ReplicationPoller, SubscriptionManager, SubscriptionsChecker}

  def start_link(args) do
    name = [name: {:via, :syn, {Postgres.Sup, args["id"]}}]
    Supervisor.start_link(__MODULE__, args, name)
  end

  @impl true
  def init(args) do
    subscribers_tid = :ets.new(Realtime.ChannelsSubscribers, [:public, :bag])
    tid_args = Map.merge(args, %{"subscribers_tid" => subscribers_tid})

    # applying tenant's migrations
    apply_migrations(args)

    children = [
      %{
        id: ReplicationPoller,
        start: {ReplicationPoller, :start_link, [args]},
        restart: :transient
      },
      %{
        id: SubscriptionManager,
        start: {SubscriptionManager, :start_link, [tid_args]},
        restart: :transient
      },
      %{
        id: SubscriptionsChecker,
        start: {SubscriptionsChecker, :start_link, [tid_args]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_all, max_restarts: 10, max_seconds: 60)
  end

  @spec apply_migrations(map()) :: [integer()]
  defp apply_migrations(args) do
    {host, port, name, user, pass} =
      decrypt_creds(
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
