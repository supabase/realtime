defmodule RealtimeWeb.TenantBroadcaster.GenRpc do
  @moduledoc "Broadcaster for tenants using :gen_rpc"

  @behaviour RealtimeWeb.TenantBroadcaster

  @impl true
  def broadcast(topic, event, msg) do
    Realtime.GenRpc.multicast(RealtimeWeb.Endpoint, :local_broadcast, [topic, event, msg], key: topic)
    :ok
  end

  @impl true
  def broadcast_from(from, topic, event, msg) do
    Realtime.GenRpc.multicast(RealtimeWeb.Endpoint, :local_broadcast_from, [from, topic, event, msg], key: topic)
    :ok
  end
end
