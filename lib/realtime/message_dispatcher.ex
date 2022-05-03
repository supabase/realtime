# This file draws from https://github.com/phoenixframework/phoenix/blob/9941711736c8464b27b40914a4d954ed2b4f5958/lib/phoenix/channel/server.ex
# License: https://github.com/phoenixframework/phoenix/blob/518a4640a70aa4d1370a64c2280d598e5b928168/LICENSE.md

defmodule Realtime.MessageDispatcher do
  @doc """
  Hook invoked by Phoenix.PubSub dispatch.
  """
  def dispatch([_ | _] = topic_subscriptions, _from, {payload, subscription_ids}) do
    _ =
      Enum.reduce(topic_subscriptions, %{}, fn
        {_pid, {:subscriber_fastlane, fastlane_pid, serializer, id, join_topic}}, cache ->
          if MapSet.member?(subscription_ids, id) do
            broadcast_message(cache, fastlane_pid, %{payload | topic: join_topic}, serializer)
          else
            cache
          end

        {_pid, {:fastlane, fastlane_pid, serializer, _event_intercepts}}, cache ->
          broadcast_message(cache, fastlane_pid, payload, serializer)

        _, cache ->
          cache
      end)

    :ok
  end

  def dispatch(_, _, _), do: :ok

  defp broadcast_message(cache, fastlane_pid, msg, serializer) do
    case cache do
      %{^serializer => encoded_msg} ->
        send(fastlane_pid, encoded_msg)
        cache

      %{} ->
        encoded_msg = serializer.fastlane!(msg)
        send(fastlane_pid, encoded_msg)
        Map.put(cache, serializer, encoded_msg)
    end
  end
end
