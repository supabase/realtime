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
  def dispatch([_ | _] = topic_subscriptions, _from, %Broadcast{payload: payload}) do
    Enum.reduce(topic_subscriptions, %{}, fn
      {_pid, {:subscriber_fastlane, fastlane_pid, serializer, id, join_topic, event, is_new_api}},
      cache ->
        if is_new_api do
          if event == "*" || event == payload.type do
            new_payload = %Broadcast{
              topic: join_topic,
              event: "postgres_changes",
              payload: %{id: id, data: payload}
            }

            broadcast_message(cache, fastlane_pid, new_payload, serializer)
          else
            cache
          end
        else
          new_payload = %Broadcast{
            topic: join_topic,
            event: payload.type,
            payload: payload
          }

          broadcast_message(cache, fastlane_pid, new_payload, serializer)
        end

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
