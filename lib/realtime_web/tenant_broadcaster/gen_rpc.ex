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

  @impl true
  def pubsub_broadcast(topic, message, dispatcher) do
    Realtime.GenRpc.multicast(Phoenix.PubSub, :local_broadcast, [Realtime.PubSub, topic, message, dispatcher],
      key: topic
    )

    :ok
  end

  @impl true
  def pubsub_broadcast_from(from, topic, message, dispatcher) do
    Realtime.GenRpc.multicast(
      Phoenix.PubSub,
      :local_broadcast_from,
      [Realtime.PubSub, from, topic, message, dispatcher],
      key: topic
    )

    :ok
  end
end
