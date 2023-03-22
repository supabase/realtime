defmodule Realtime.MessageDispatcher do
  @moduledoc """
  Hook invoked by Phoenix.PubSub dispatch.
  """

  alias Phoenix.Socket.Broadcast
  alias Realtime.Tenants
  alias Realtime.GenCounter

  def dispatch(
        [_ | _] = topic_subscriptions,
        _from,
        %Broadcast{payload: payload} = msg
      ) do
    {sub_ids, new_payload} = Map.pop(payload, :subscription_ids)

    _ =
      Enum.reduce(topic_subscriptions, %{}, fn
        {_pid,
         {:db_change_fastlane, fastlane_pid, serializer, ids, join_topic, tenant, is_new_api}},
        cache ->
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
              new_msg =
                if is_new_api do
                  %Broadcast{
                    topic: join_topic,
                    event: "postgres_changes",
                    payload: %{ids: valid_ids, data: new_payload}
                  }
                else
                  %Broadcast{
                    topic: join_topic,
                    event: new_payload.type,
                    payload: new_payload
                  }
                end

              db_event_count(tenant)
              broadcast_message(cache, fastlane_pid, new_msg, serializer)

            _ ->
              cache
          end

        {_pid, {:broadcast_fastlane, fastlane_pid, serializer, tenant}}, cache ->
          broadcast_event_count(tenant)
          broadcast_message(cache, fastlane_pid, msg, serializer)
      end)

    :ok
  end

  defp broadcast_message(cache, fastlane_pid, msg, serializer) do
    case cache do
      %{^msg => encoded_msg} ->
        send(fastlane_pid, encoded_msg)
        cache

      %{} ->
        encoded_msg = serializer.fastlane!(msg)
        send(fastlane_pid, encoded_msg)
        Map.put(cache, msg, encoded_msg)
    end
  end

  defp db_event_count(tenant) do
    Tenants.db_events_per_second_key(tenant)
    |> GenCounter.add()
  end

  defp broadcast_event_count(tenant) do
    Tenants.events_per_second_key(tenant)
    |> GenCounter.add()
  end
end
