defmodule Extensions.Postgres.DynamicSupervisor do
  use Supervisor

  alias Extensions.Postgres
  alias Postgres.{ReplicationPoller, SubscriptionManager, SubscriptionsChecker}

  import Realtime.Helpers, only: [decrypt!: 2]

  @queue_target 5_000
  @pool_size 5

  def start_link(args) do
    name = [name: {:via, :syn, {Postgres.Sup, args["id"]}}]
    Supervisor.start_link(__MODULE__, args, name)
  end

  @impl true
  def init(args) do
    %{
      "db_host" => host,
      "db_name" => name,
      "db_user" => user,
      "db_password" => pass
    } = args

    {:ok, conn} = connect_db(host, name, user, pass)
    subscribers_tid = :ets.new(Realtime.ChannelsSubscribers, [:public, :set])
    conn_args = Map.merge(args, %{"conn" => conn, "subscribers_tid" => subscribers_tid})

    children = [
      %{
        id: ReplicationPoller,
        start: {ReplicationPoller, :start_link, [args]},
        restart: :transient
      },
      %{
        id: SubscriptionManager,
        start: {SubscriptionManager, :start_link, [conn_args]},
        restart: :transient
      },
      %{
        id: SubscriptionsChecker,
        start: {SubscriptionsChecker, :start_link, [conn_args]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  @spec connect_db(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, pid} | {:error, Postgrex.Error.t() | term()}
  def connect_db(host, name, user, pass) do
    secure_key = Application.get_env(:realtime, :db_enc_key)

    host = decrypt!(host, secure_key)
    name = decrypt!(name, secure_key)
    pass = decrypt!(pass, secure_key)
    user = decrypt!(user, secure_key)

    Postgrex.start_link(
      hostname: host,
      database: name,
      password: pass,
      username: user,
      pool_size: @pool_size,
      queue_target: @queue_target
    )
  end
end
