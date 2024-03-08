defmodule Extensions.PostgresCdcRls.WorkerSupervisor do
  @moduledoc false
  use Supervisor

  alias Extensions.PostgresCdcRls

  alias PostgresCdcRls.{
    ReplicationPoller,
    SubscriptionManager,
    SubscriptionsChecker
  }

  alias Realtime.Api
  alias Realtime.PostgresCdc.Exception

  def start_link(args) do
    name = PostgresCdcRls.supervisor_id(args["id"], args["region"])
    Supervisor.start_link(__MODULE__, args, name: {:via, :syn, name})
  end

  @impl true
  def init(%{"id" => tenant} = args) when is_binary(tenant) do
    unless Api.get_tenant_by_external_id(tenant, :primary), do: raise(Exception)

    tid_args = Map.merge(args, %{"subscribers_tid" => :ets.new(__MODULE__, [:public, :bag])})

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

    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10, max_seconds: 60)
  end
end
