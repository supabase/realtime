defmodule Realtime.Tenants.CachePubSubHandler do
  use GenServer

  require Logger

  alias Realtime.Tenants.Cache

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(topics: topics) do
    Enum.each(topics, fn topic -> Phoenix.PubSub.subscribe(Realtime.PubSub, topic) end)
    {:ok, []}
  end

  @impl true
  def handle_info({_, tenant_id}, state) do
    Logger.warn("Triggering cache invalidation", external_id: tenant_id)
    Cache.invalidate_tenant_cache(tenant_id)
    {:noreply, state}
  end
end
