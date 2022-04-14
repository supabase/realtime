defmodule Extensions.Postgres.SubscribersNotification do
  require Logger

  alias Phoenix.Socket.Broadcast
  alias Realtime.{MessageDispatcher, PubSub}

  # @topic "room"
  @topic "realtime"

  def broadcast_change(topics, %{subscription_ids: subscription_ids} = change, tenant) do
    payload =
      Map.filter(change, fn {key, _} ->
        !Enum.member?([:is_rls_enabled, :subscription_ids], key)
      end)

    for topic <- topics do
      broadcast = %Broadcast{
        topic: "#{@topic}:#{topic}",
        event: "realtime",
        payload: %{payload: payload, event: payload.type}
      }

      Phoenix.PubSub.broadcast_from(
        PubSub,
        self(),
        "#{tenant}:#{topic}",
        {broadcast, subscription_ids, topics},
        MessageDispatcher
      )
    end
  end

  def notify_subscribers([_ | _] = changes, id) do
    for {change, table_topics} <- changes_topics(changes) do
      broadcast_change(table_topics, change, id)
    end
  end

  def notify_subscribers(_, _), do: :ok

  def changes_topics(changes) do
    Enum.reduce(changes, [], fn change, acc ->
      case change do
        %{schema: schema, table: table, type: type}
        when is_binary(schema) and is_binary(table) and is_binary(type) ->
          schema_topic = "#{schema}"
          table_topic = "#{schema_topic}:#{table}"

          # Shout to specific columns - e.g. "realtime:public:users.id=eq.2"
          if type in ["INSERT", "UPDATE", "DELETE"] do
            record_key = if type == "DELETE", do: :old_record, else: :record

            record = Map.get(change, record_key)

            filtered =
              is_map(record) &&
                Enum.reduce(record, [], fn {k, v}, acc ->
                  with true <- is_notification_key_valid(v),
                       {:ok, stringified_v} <- stringify_value(v),
                       true <- is_notification_key_length_valid(stringified_v) do
                    ["#{table_topic}:#{k}=eq.#{stringified_v}" | acc]
                  end
                end)

            [{change, ["*", table_topic] ++ filtered} | acc]
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp is_notification_key_valid(v) do
    v != nil and v != :unchanged_toast
  end

  defp stringify_value(v) when is_binary(v), do: {:ok, v}
  defp stringify_value(v), do: Jason.encode(v)

  defp is_notification_key_length_valid(v), do: String.length(v) < 100
end
