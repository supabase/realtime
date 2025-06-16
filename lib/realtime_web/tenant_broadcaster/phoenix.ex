defmodule RealtimeWeb.TenantBroadcaster.Phoenix do
  @moduledoc "Broadcaster for tenants using Phoenix Endpoint"

  alias RealtimeWeb.Endpoint

  @behaviour RealtimeWeb.TenantBroadcaster

  @impl true
  def broadcast(topic, event, msg), do: Endpoint.broadcast(topic, event, msg)

  @impl true
  def broadcast_from(from, topic, event, msg), do: Endpoint.broadcast_from(from, topic, event, msg)
end
