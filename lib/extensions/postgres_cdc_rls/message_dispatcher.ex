# This file draws from https://github.com/phoenixframework/phoenix/blob/9941711736c8464b27b40914a4d954ed2b4f5958/lib/phoenix/channel/server.ex
# License: https://github.com/phoenixframework/phoenix/blob/518a4640a70aa4d1370a64c2280d598e5b928168/LICENSE.md

defmodule Extensions.PostgresCdcRls.MessageDispatcher do
  @moduledoc """
  Hook invoked by Phoenix.PubSub dispatch.
  """

  alias Phoenix.Socket.Broadcast

  def dispatch([_ | _] = topic_subscriptions, _from, {type, payload, sub_ids}) do
    data = Jason.Fragment.new(payload)

    _ =
      Enum.reduce(topic_subscriptions, %{}, fn
        {_pid, {:subscriber_fastlane, fastlane_pid, serializer, ids, join_topic, is_new_api}}, cache ->
          for {bin_id, id} <- ids, reduce: [] do
            acc ->
              if MapSet.member?(sub_ids, bin_id) do
                [id | acc]
              else
                acc
              end
          end
          |> case do
            [_ | _] = valid_ids ->
              cache_key =
                if is_new_api do
                  {serializer, join_topic, valid_ids}
                else
                  {serializer, join_topic}
                end

              broadcast_message(cache, cache_key, fastlane_pid, type, data)

            _ ->
              cache
          end
      end)

    :ok
  end

  defp broadcast_message(cache, cache_key, fastlane_pid, type, data) do
    case cache do
      %{^cache_key => {:ok, encoded_msg}} ->
        send(fastlane_pid, encoded_msg)
        cache

      %{^cache_key => {:error, _reason}} ->
        cache

      %{} ->
        result = encode(cache_key, type, data)
        with {:ok, encoded_msg} <- result, do: send(fastlane_pid, encoded_msg)
        Map.put(cache, cache_key, result)
    end
  end

  defp encode(cache_key, type, data) do
    serializer = elem(cache_key, 0)
    {:ok, serializer.fastlane!(broadcast(cache_key, type, data))}
  rescue
    error -> {:error, error}
  end

  defp broadcast({_serializer, join_topic, valid_ids}, _type, data),
    do: %Broadcast{topic: join_topic, event: "postgres_changes", payload: %{ids: valid_ids, data: data}}

  defp broadcast({_serializer, join_topic}, type, data),
    do: %Broadcast{topic: join_topic, event: type, payload: data}
end
