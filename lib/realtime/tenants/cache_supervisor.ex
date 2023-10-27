defmodule Realtime.Tenants.CacheSupervisor do
  use Supervisor

  alias Phoenix.PubSub
  alias Realtime.Tenants.Cache
  alias Realtime.Tenants.CachePubSubHandler

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {CachePubSubHandler, topics: ["realtime:operations"]},
      Cache
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def handle_info({_, tenant_id}, state) do
    Cache.invalidate_tenant_cache(tenant_id)
    {:noreply, state}
  end
end
