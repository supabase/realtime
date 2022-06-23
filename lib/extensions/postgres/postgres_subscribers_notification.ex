defmodule Extensions.Postgres.SubscribersNotification do
  require Logger

  alias Realtime.{MessageDispatcher, PubSub}

  def broadcast_change(topic, %{subscription_ids: subscription_ids} = change) do
    payload =
      Map.filter(change, fn {key, _} ->
        !Enum.member?([:is_rls_enabled, :subscription_ids], key)
      end)

    Phoenix.PubSub.broadcast_from(
      PubSub,
      self(),
      topic,
      {payload, subscription_ids},
      MessageDispatcher
    )
  end

  def notify_subscribers([_ | _] = changes, tenant) do
    for change <- changes do
      broadcast_change("realtime:postgres:" <> tenant, change)
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
            filtered = filtered_record(record, table_topic)
            [{change, ["*", table_topic] ++ filtered} | acc]
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp filtered_record(record, table_topic) do
    is_map(record) &&
      Enum.reduce(record, [], fn {k, v}, acc ->
        with true <- is_notification_key_valid(v),
             {:ok, stringified_v} <- stringify_value(v),
             true <- is_notification_key_length_valid(stringified_v) do
          ["#{table_topic}:#{k}=eq.#{stringified_v}" | acc]
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
