# This file draws from https://github.com/phoenixframework/phoenix/blob/9941711736c8464b27b40914a4d954ed2b4f5958/lib/phoenix/channel/server.ex
# License: https://github.com/phoenixframework/phoenix/blob/518a4640a70aa4d1370a64c2280d598e5b928168/LICENSE.md

defmodule Realtime.MessageDispatcher do
  alias Phoenix.Socket.Broadcast

  @doc """
  Hook invoked by Phoenix.PubSub dispatch.
  """
  @spec dispatch(
          [{pid, nil | {:fastlane | :subscriber_fastlane, pid, atom, binary}}],
          pid,
          Phoenix.Socket.Broadcast.t()
        ) :: :ok
  def dispatch([_ | _] = topic_subscriptions, _from, %Broadcast{payload: payload} = msg) do
    {subscription_ids, new_payload} = Map.pop(payload, :subscription_ids)
    new_msg = %{msg | payload: new_payload}

    Enum.reduce(topic_subscriptions, %{}, fn
      {_pid,
       {:subscriber_fastlane, fastlane_pid, serializer, subscription_id, join_topic, is_new_api}},
      cache ->
        if MapSet.member?(subscription_ids, subscription_id) do
          new_payload =
            if is_new_api do
              %Broadcast{
                topic: join_topic,
                event: "realtime",
                payload: %{payload: new_payload, event: new_payload.type}
              }
            else
              %Broadcast{
                topic: join_topic,
                event: new_payload.type,
                payload: new_payload
              }
            end

          broadcast_message(cache, fastlane_pid, new_payload, serializer)
        else
          cache
        end

      {_pid, {:fastlane, fastlane_pid, serializer, _event_intercepts}}, cache ->
        broadcast_message(cache, fastlane_pid, new_msg, serializer)

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
