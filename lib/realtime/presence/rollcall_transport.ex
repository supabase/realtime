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

    {:ok, %{scope: scope, pubsub: pubsub, start_time: System.system_time(:millisecond)}}
  end

  @impl true
  def active?(%{scope: scope}) do
    Forum.Census.local_member_count(:users, scope) > 0
  end

  @impl true
  def heartbeat(%{scope: scope, pubsub: pubsub}, message) do
    Phoenix.PubSub.broadcast_from(pubsub, self(), topic_for(scope), wrap(scope, message))
    :ok
  end

  @impl true
  def publish(%{scope: scope, pubsub: pubsub} = state, partition, diff) do
    case Realtime.Presence.mode(scope) do
      :rollcall ->
        Phoenix.PubSub.local_broadcast(
          pubsub,
          partition,
          broadcast_message(partition, diff, Map.get(state, :start_time))
        )

      :shadow ->
        {_msg, metrics_envelopes} = Metrics.strip_diff(broadcast_message(partition, diff, Map.get(state, :start_time)))

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

  defp broadcast_message(partition, diff, start_time) do
    %Phoenix.Socket.Broadcast{
      topic: partition,
      event: "presence_diff",
      payload:
        diff
        |> strip_expired_stamps(start_time)
        |> Realtime.Presence.Encoder.diff()
    }
  end

  defp strip_expired_stamps({joins, leaves}, start_time) do
    {
      Enum.map(joins, &strip_expired_stamp(&1, start_time)),
      Enum.map(leaves, &strip_expired_stamp(&1, start_time))
    }
  end

  defp strip_expired_stamp({ref, key, meta}, start_time) do
    {ref, key, Metrics.strip_expired_stamp(meta, start_time)}
  end
end
