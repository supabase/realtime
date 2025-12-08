defmodule Realtime.BeaconPubSubAdapter do
  @moduledoc "Beacon adapter to use PubSub"

  import Kernel, except: [send: 2]

  @behaviour Beacon.Adapter

  @impl true
  def register(scope) do
    :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, topic(scope))
  end

  @impl true
  def broadcast(scope, message) do
    Phoenix.PubSub.broadcast_from(Realtime.PubSub, self(), topic(scope), message)
  end

  @impl true
  def broadcast(scope, _nodes, message) do
    # Notice here that we don't filter by nodes, as PubSub broadcasts to all subscribers
    # We are broadcasting to everyone because we want to use the fact that Realtime.PubSub uses
    # regional broadcasting which is more efficient in this multi-region setup

    broadcast(scope, message)
  end

  @impl true
  def send(scope, node, message) do
    Phoenix.PubSub.direct_broadcast(node, Realtime.PubSub, topic(scope), message)
  end

  defp topic(scope), do: "beacon:#{scope}"
end
