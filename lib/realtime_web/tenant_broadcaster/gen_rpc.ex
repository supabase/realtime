defmodule RealtimeWeb.TenantBroadcaster.GenRpc do
  @behaviour RealtimeWeb.TenantBroadcaster

  @impl true
  def broadcast(topic, event, msg) do
    Realtime.GenRpc.multicall(RealtimeWeb.Endpoint, :local_broadcast, [topic, event, msg])
    :ok
  end

  @impl true
  def broadcast_from(from, topic, event, msg) do
    Realtime.GenRpc.multicall(RealtimeWeb.Endpoint, :local_broadcast_from, [from, topic, event, msg])
    :ok
  end
end
