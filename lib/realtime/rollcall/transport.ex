defmodule Realtime.Rollcall.Transport do
  @moduledoc """
  Implements Rollcall.Transport for use in Realtime.
  """
  @behaviour Rollcall.Transport

  require Logger

  @impl true
  def init(scope, opts) do
    pubsub = Keyword.get(opts, :pubsub, Realtime.PubSub)

    :ok = Phoenix.PubSub.subscribe(pubsub, topic_for(scope))
    join_muster(Keyword.get(opts, :muster_scope), scope)

    {:ok, %{scope: scope, pubsub: pubsub}}
  end

  @impl true
  def heartbeat(%{scope: scope, pubsub: pubsub}, message) do
    Phoenix.PubSub.broadcast_from(pubsub, self(), topic_for(scope), wrap(scope, message))
    :ok
  end

  @impl true
  def unwrap(_transport, {:tb, scope, message}) do
    {:ok, scope, message}
  end

  def unwrap(_transport, _message), do: :ignore

  # The tracker joins the Muster group of its tenant, so the routing delivers
  # heartbeats to this node. The join is temporary. The channel join registers
  # the interest of the node when the channel hook exists. The join blocks the
  # tracker until Muster replies.
  defp join_muster(nil, _scope), do: :ok

  defp join_muster(muster_scope, scope) do
    case Forum.Muster.join(muster_scope, scope, self()) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("Rollcall tracker could not join Muster for #{scope}: #{inspect(reason)}")
    end
  end

  defp wrap(scope, message), do: {:tb, scope, message}

  defp topic_for(scope), do: "rollcall:" <> scope
end
