defmodule Realtime.SubscribersNotification do
  require Logger

  alias Realtime.Adapters.Changes.Transaction
  alias Realtime.Configuration.Configuration
  alias Realtime.ConfigurationManager
  alias RealtimeWeb.RealtimeChannel

  @topic "realtime"

  def notify(%Transaction{changes: changes} = txn) when is_list(changes) do
    {:ok, %Configuration{realtime: realtime_config, webhooks: webhooks_config}} =
      ConfigurationManager.get_config()

    :ok = notify_subscribers(changes, realtime_config)
    :ok = Realtime.WebhookConnector.notify(txn, webhooks_config)
  end

  def notify(_txn) do
    :ok
  end

  defp notify_subscribers([_ | _] = changes, [_ | _] = realtime_config) do
    # For every change in the txn.changes, we want to broadcast it specific listeners
    # Example Change:
    # %Realtime.Adapters.Changes.UpdatedRecord{
    #   columns: [
    #     %Realtime.Adapters.Postgres.Decoder.Messages.Relation.Column{ flags: [:key], name: "id", type: "int8", type_modifier: 4294967295 },
    #     %Realtime.Adapters.Postgres.Decoder.Messages.Relation.Column{ flags: [], name: "name", type: "text", type_modifier: 4294967295 }
    #   ],
    #   commit_timestamp: nil,
    #   old_record: %{},
    #   record: %{"id" => "2", "name" => "Jane Doe2"},
    #   schema: "public",
    #   table: "users",
    #   type: "UPDATE"
    # }

    Enum.each(changes, fn change ->
      case change do
        %{schema: schema, table: table, type: type}
        when is_binary(schema) and is_binary(table) and is_binary(type) ->
          schema_topic = [@topic, ":", schema] |> IO.iodata_to_binary()
          table_topic = [schema_topic, ":", table] |> IO.iodata_to_binary()

          # Get only the config which includes this event type (INSERT | UPDATE | DELETE | TRUNCATE)
          event_config =
            Enum.filter(realtime_config, fn config ->
              case config do
                %Realtime.Configuration.Realtime{events: [_ | _] = events} -> type in events
                _ -> false
              end
            end)

          # Shout to specific schema - e.g. "realtime:public"
          if has_schema(event_config, schema) do
            RealtimeChannel.handle_realtime_transaction(schema_topic, change)
          end

          # Special case for notifiying "*"
          if has_schema(event_config, "*") do
            [@topic, ":*"]
            |> IO.iodata_to_binary()
            |> RealtimeChannel.handle_realtime_transaction(change)
          end

          # Shout to specific table - e.g. "realtime:public:users"
          if has_table(event_config, schema, table) do
            RealtimeChannel.handle_realtime_transaction(table_topic, change)
          end

          # Shout to specific columns - e.g. "realtime:public:users.id=eq.2"
          case type do
            type when type in ["INSERT", "UPDATE"] ->
              record = Map.get(change, :record)

              is_map(record) &&
                Enum.each(record, fn {k, v} ->
                  should_notify_column = has_column(event_config, schema, table, k)

                  if is_valid_notification_key(v) and should_notify_column do
                    [table_topic, ":", k, "=eq.", v]
                    |> IO.iodata_to_binary()
                    |> RealtimeChannel.handle_realtime_transaction(change)
                  end
                end)

            "DELETE" ->
              old_record = Map.get(change, :old_record)

              is_map(old_record) &&
                Enum.each(old_record, fn {k, v} ->
                  should_notify_column = has_column(event_config, schema, table, k)

                  if is_valid_notification_key(v) and should_notify_column do
                    [table_topic, ":", k, "=eq.", v]
                    |> IO.iodata_to_binary()
                    |> RealtimeChannel.handle_realtime_transaction(change)
                  end
                end)

            "TRUNCATE" ->
              nil
          end

        _ ->
          nil
      end
    end)
  end

  defp notify_subscribers(_txn, _config), do: :ok

  defp has_schema(config, schema) do
    # Determines whether the Realtime config has a specific schema relation
    valid_patterns = ["*", schema]
    Enum.any?(config, fn c -> c.relation in valid_patterns end)
  end

  defp has_table(config, schema, table) do
    # Determines whether the Realtime config has a specific table relation
    # Construct an array of valid patterns: "*:*", "public:todos", etc
    valid_patterns =
      for schema_keys <- ["*", schema],
          table_keys <- ["*", table],
          do: [schema_keys, ":", table_keys] |> IO.iodata_to_binary()

    Enum.any?(config, fn c -> c.relation in valid_patterns end)
  end

  defp has_column(config, schema, table, column) do
    # Determines whether the Realtime config has a specific column relation
    # Construct an array of valid patterns: "*:*:*", "public:todos", etc
    valid_patterns =
      for schema_keys <- ["*", schema],
          table_keys <- ["*", table],
          column_keys <- ["*", column],
          do: [schema_keys, ":", table_keys, ":", column_keys] |> IO.iodata_to_binary()

    Enum.any?(config, fn c -> c.relation in valid_patterns end)
  end

  defp is_valid_notification_key(v) when is_binary(v) do
    String.length(v) < 100
  end

  defp is_valid_notification_key(_v), do: false
end
