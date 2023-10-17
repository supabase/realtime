defmodule Extensions.PostgresCdcRls.WorkerSupervisor do
  @moduledoc false
  use Supervisor

  alias Extensions.PostgresCdcRls

  alias PostgresCdcRls.{
    ReplicationPoller,
    SubscriptionManager,
    SubscriptionsChecker
  }

  alias Realtime.Tenants.Migrations

  def start_link(args) do
    name = PostgresCdcRls.supervisor_id(args["id"], args["region"])
    Supervisor.start_link(__MODULE__, args, name: {:via, :syn, name})
  end

  @impl true
  def init(args) do
    tid_args =
      Map.merge(args, %{
        "subscribers_tid" => :ets.new(__MODULE__, [:public, :bag])
      })

    children = [
      %{
        id: Migrations,
        start: {Migrations, :start_link, [args]},
        restart: :transient
      },
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
