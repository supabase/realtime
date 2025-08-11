defmodule RealtimeWeb.TenantBroadcaster do
  @moduledoc """
  gen_rpc broadcaster
  """

  alias Phoenix.Endpoint
  alias Phoenix.PubSub

  @spec broadcast(Endpoint.topic(), Endpoint.event(), Endpoint.msg()) :: :ok
  def broadcast(topic, event, msg) do
    Realtime.GenRpc.multicast(RealtimeWeb.Endpoint, :local_broadcast, [topic, event, msg], key: topic)
    :ok
  end

  @spec broadcast_from(from :: pid, Endpoint.topic(), Endpoint.event(), Endpoint.msg()) :: :ok
  def broadcast_from(from, topic, event, msg) do
    Realtime.GenRpc.multicast(RealtimeWeb.Endpoint, :local_broadcast_from, [from, topic, event, msg], key: topic)
    :ok
  end

  @spec pubsub_broadcast(PubSub.topic(), PubSub.message(), PubSub.dispatcher()) :: :ok
  def pubsub_broadcast(topic, message, dispatcher) do
    Realtime.GenRpc.multicast(PubSub, :local_broadcast, [Realtime.PubSub, topic, message, dispatcher], key: topic)

    :ok
  end

  @spec pubsub_broadcast_from(from :: pid, PubSub.topic(), PubSub.message(), PubSub.dispatcher()) :: :ok
  def pubsub_broadcast_from(from, topic, message, dispatcher) do
    Realtime.GenRpc.multicast(
      PubSub,
      :local_broadcast_from,
      [Realtime.PubSub, from, topic, message, dispatcher],
      key: topic
    )

    :ok
  end
end
