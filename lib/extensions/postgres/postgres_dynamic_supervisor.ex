defmodule Extensions.Postgres.DynamicSupervisor do
  use Supervisor

  alias Extensions.Postgres
  alias Postgres.{ReplicationPoller, SubscriptionManager}

  def start_link(args) do
    Supervisor.start_link(__MODULE__, args)
  end

  @impl true
  def init(args) do
    subscribers_tid = :ets.new(Realtime.ChannelsSubscribers, [:public, :set])

    children = [
      %{
        id: ReplicationPoller,
        start: {ReplicationPoller, :start_link, [args]},
        restart: :transient
      },
      %{
        id: SubscriptionManager,
        start:
          {SubscriptionManager, :start_link,
           [
             %{
               args: args,
               subscribers_tid: subscribers_tid
             }
           ]},
        restart: :transient
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
