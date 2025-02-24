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
  def init(_) do
    Phoenix.PubSub.subscribe(Realtime.PubSub, "realtime:invalidate_cache")
    {:ok, []}
  end

  @impl true
  def handle_info(tenant_id, state) do
    Logger.warning("Triggering cache invalidation", external_id: tenant_id)
    Cache.invalidate_tenant_cache(tenant_id)
    {:noreply, state}
  end
end
