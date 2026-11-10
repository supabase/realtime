defmodule Realtime.Presence.RollcallTransport do
  @moduledoc """
  Implements Rollcall.Transport for use in Realtime.

  `publish/3` depends on the presence mode of the scope, see `Realtime.Presence`.

    * Rollcall mode: it broadcasts the `presence_diff` to the subscribers of the partition.
    * Shadow mode: it broadcasts nothing, because Phoenix already notifies the clients. It records
      the notify latency of the diff once, with the path `:transport`.
    * Phoenix mode: it does nothing.
  """
  alias Realtime.Presence.Metrics

  @behaviour Rollcall.Transport

  @impl true
  def init(scope, opts) do
    pubsub = Keyword.get(opts, :pubsub, Realtime.PubSub)

    Phoenix.PubSub.subscribe(pubsub, topic_for(scope))

    {:ok, %{scope: scope, pubsub: pubsub}}
  end

  @impl true
  def has_interest?(%{scope: scope}) do
    Forum.Census.local_member_count(:users, scope) > 0
  end

  @impl true
  def heartbeat(%{scope: scope, pubsub: pubsub}, message) do
    Phoenix.PubSub.broadcast_from(pubsub, self(), topic_for(scope), wrap(scope, message))
    :ok
  end

  @impl true
  def publish(%{scope: scope, pubsub: pubsub}, partition, diff) do
    case Realtime.Presence.mode(scope) do
      :rollcall ->
        Phoenix.PubSub.local_broadcast(
          pubsub,
          partition,
          broadcast_message(partition, diff),
          RealtimeWeb.RealtimeChannel.MessageDispatcher
        )

      :shadow ->
        {_msg, metrics_envelopes} = Metrics.strip_diff(broadcast_message(partition, diff))

        context = Metrics.context(scope, :transport)
        Metrics.record(metrics_envelopes, context)

        :ok

      :phoenix ->
        :ok
    end
  end

  @impl true
  def unwrap(_transport, {:tb, scope, message}) do
    {:ok, scope, message}
  end

  def unwrap(_transport, _message), do: :ignore

  defp wrap(scope, message), do: {:tb, scope, message}

  defp topic_for(scope), do: "rollcall:" <> scope

  defp broadcast_message(partition, diff) do
    %Phoenix.Socket.Broadcast{
      topic: partition,
      event: "presence_diff",
      payload: Realtime.Presence.Encoder.diff(diff)
    }
  end
end
