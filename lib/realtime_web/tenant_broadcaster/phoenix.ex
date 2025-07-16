defmodule RealtimeWeb.TenantBroadcaster.Phoenix do
  @moduledoc "Broadcaster for tenants using Phoenix Endpoint"

  alias RealtimeWeb.Endpoint

  @behaviour RealtimeWeb.TenantBroadcaster

  @impl true
  def broadcast(topic, event, msg), do: Endpoint.broadcast(topic, event, msg)

  @impl true
  def broadcast_from(from, topic, event, msg), do: Endpoint.broadcast_from(from, topic, event, msg)

  @impl true
  def pubsub_broadcast(topic, message, dispatcher) do
    Phoenix.PubSub.broadcast(Realtime.PubSub, topic, message, dispatcher)
  end

  @impl true
  def pubsub_broadcast_from(from, topic, message, dispatcher) do
    Phoenix.PubSub.broadcast_from(Realtime.PubSub, from, topic, message, dispatcher)
  end
end
