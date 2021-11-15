# This file draws from https://github.com/phoenixframework/phoenix/blob/9941711736c8464b27b40914a4d954ed2b4f5958/lib/phoenix/channel/server.ex
# License: https://github.com/phoenixframework/phoenix/blob/518a4640a70aa4d1370a64c2280d598e5b928168/LICENSE.md

defmodule Realtime.MessageDispatcher do
  alias Phoenix.Socket.Broadcast

  @doc """
  Hook invoked by Phoenix.PubSub dispatch.
  """
  @spec dispatch(
          [{pid, nil | {:fastlane | :user_fastlane, pid, atom, binary}}],
          pid,
          Phoenix.Socket.Broadcast.t()
        ) :: :ok
  def dispatch(subscribers, _from, %Broadcast{payload: payload} = msg) do
    {is_rls_enabled, new_payload} = Map.pop(payload, :is_rls_enabled)
    {users, new_payload} = Map.pop(new_payload, :users)
    new_msg = %{msg | payload: new_payload}

    Enum.reduce(subscribers, %{}, fn
      {_pid, {:user_fastlane, fastlane_pid, serializer, user_id}}, cache ->
        if !is_rls_enabled or MapSet.member?(users, user_id) do
          broadcast_message(cache, fastlane_pid, new_msg, serializer)
        else
          cache
        end

      {_pid, {:fastlane, fastlane_pid, serializer, _event_intercepts}}, cache ->
        if !is_rls_enabled do
          broadcast_message(cache, fastlane_pid, new_msg, serializer)
        else
          cache
        end

      {_pid, nil}, cache ->
        cache
    end)

    :ok
  end

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
