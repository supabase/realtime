defmodule Extensions.Postgres.DynamicSupervisor do
  use Supervisor

  alias Extensions.Postgres
  alias Postgres.{ReplicationPoller, SubscriptionManager}
  alias Realtime.Repo

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  @impl true
  def init(args) do
    run_migrations(args)

    {:ok, conn} =
      Postgrex.start_link(
        hostname: args[:db_host],
        database: args[:db_name],
        password: args[:db_pass],
        username: args[:db_user],
        queue_target: 5000,
        pool_size: 1
      )

    :global.register_name({:db_instance, args[:id]}, conn)
    subscribers_tid = :ets.new(Realtime.ChannelsSubscribers, [:public, :set])

    opts = [
      id: args[:id],
      conn: conn,
      backoff_type: :rand_exp,
      backoff_min: 100,
      backoff_max: 120_000,
      poll_interval_ms: args[:poll_interval_ms],
      publication: args[:publication],
      slot_name: args[:slot_name],
      max_changes: args[:max_changes],
      max_record_bytes: args[:max_record_bytes]
    ]

    children = [
      %{
        id: ReplicationPoller,
        start: {ReplicationPoller, :start_link, [opts]},
        restart: :transient
      },
      %{
        id: SubscriptionManager,
        start:
          {SubscriptionManager, :start_link,
           [
             %{
               conn: conn,
               id: args[:id],
               subscribers_tid: subscribers_tid,
               publication: args[:publication]
             }
           ]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp run_migrations(args) do
    {:ok, repo} =
      Repo.start_link(
        name: nil,
        hostname: args[:db_host],
        database: args[:db_name],
        password: args[:db_pass],
        username: args[:db_user]
      )

    Repo.put_dynamic_repo(repo)

    try do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(
          Repo,
          &Ecto.Migrator.run(
            &1,
            [Ecto.Migrator.migrations_path(&1, "postgres/migrations")],
            :up,
            all: true,
            prefix: "realtime"
          )
        )
    after
      Repo.stop()
    end
  end
end
