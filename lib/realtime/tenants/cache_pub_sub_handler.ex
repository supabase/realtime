defmodule Realtime.Tenants.CachePubSubHandler do
  @moduledoc """
  Process that listens to PubSub messages and triggers tenant cache invalidation.
  """
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
  def handle_info({action, tenant_id}, state)
      when action in [:suspend_tenant, :unsuspend_tenant, :invalidate_cache] do
    Logger.warning("Triggering cache invalidation", external_id: tenant_id)
    Cache.invalidate_tenant_cache(tenant_id)
    {:noreply, state}
  end
end
