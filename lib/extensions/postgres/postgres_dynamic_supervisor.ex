defmodule Extensions.Postgres.DynamicSupervisor do
  use Supervisor

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
end
