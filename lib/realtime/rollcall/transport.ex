defmodule Realtime.Rollcall.Transport do
  @moduledoc """
  Implements Rollcall.Transport for use in Realtime.
  """
  @behaviour Rollcall.Transport

  @impl true
  def init(scope, opts) do
    pubsub = Keyword.get(opts, :pubsub, Realtime.PubSub)

    Phoenix.PubSub.subscribe(pubsub, topic_for(scope))

    {:ok, %{scope: scope, pubsub: pubsub}}
  end

  @impl true
  def heartbeat(%{scope: scope, pubsub: pubsub}, message) do
    Phoenix.PubSub.broadcast_from(pubsub, self(), topic_for(scope), wrap(scope, message))
    :ok
  end

  # TODO: Check the feature flag before the broadcast. A later PR adds the check.
  # The function is safe until then, because nothing calls it.
  @impl true
  def publish(%{pubsub: pubsub}, partition, diff) do
    broadcast = %Phoenix.Socket.Broadcast{
      topic: partition,
      event: "presence_diff",
      payload: Realtime.Presence.Encoder.diff(diff)
    }

    Phoenix.PubSub.local_broadcast(pubsub, partition, broadcast, RealtimeWeb.RealtimeChannel.MessageDispatcher)
  end

  @impl true
  def unwrap(_transport, {:tb, scope, message}) do
    {:ok, scope, message}
  end

  def unwrap(_transport, _message), do: :ignore

  defp wrap(scope, message), do: {:tb, scope, message}

  defp topic_for(scope), do: "rollcall:" <> scope
end
