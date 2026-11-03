defmodule Realtime.Rollcall.Transport do
  @moduledoc """
  Implements Rollcall.Transport for use in Realtime.
  """
  @behaviour Rollcall.Transport

  @impl true
  def init(scope, opts) do
    pubsub = Keyword.get(opts, :pubsub, Realtime.PubSub)

    :ok = Phoenix.PubSub.subscribe(pubsub, topic_for(scope))

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

  defp wrap(scope, message), do: {:tb, scope, message}

  defp topic_for(scope), do: "rollcall:" <> scope
end
