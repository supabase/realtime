defmodule Realtime.SubscribersNotification do
  use GenServer
  require Logger

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Send notification events via Phoenix Channels to subscribers
  """
  def notify(txn) do
    GenServer.call(__MODULE__, {:notify, txn})
  end

  @impl true
  def init(nil) do
    {:ok, nil}
  end

  @impl true
  def handle_call({:notify, txn}, _from, nil) do
    notify_subscribers(txn)
    notify_connectors(txn)
    {:reply, :ok, nil}
  end

  defp notify_subscribers(txn) do
    # For every change in the txn.changes, we want to broadcast it specific listeners
    # Example Change:
    # %Realtime.Adapters.Changes.UpdatedRecord{
    #   columns: [
    #     %Realtime.Decoder.Messages.Relation.Column{ flags: [:key], name: "id", type: "int8", type_modifier: 4294967295 },
    #     %Realtime.Decoder.Messages.Relation.Column{ flags: [], name: "name", type: "text", type_modifier: 4294967295 }
    #   ],
    #   commit_timestamp: nil,
    #   old_record: %{},
    #   record: %{"id" => "2", "name" => "Jane Doe2"},
    #   schema: "public",
    #   table: "users",
    #   type: "UPDATE"
    # }

    {:ok, realtime_config} = Realtime.ConfigurationManager.get_config(:realtime)

    for change <- txn.changes do
      topic = "realtime"
      schema_topic = "#{topic}:#{change.schema}"
      table_topic = "#{schema_topic}:#{change.table}"
      # Logger.debug inspect(change, pretty: true)

      # Get only the config which includes this event type (INSERT | UPDATE | DELETE | TRUNCATE)
      event_config =
        Enum.filter(realtime_config, fn config ->
          change.type in config.events
        end)

      # Shout to specific schema - e.g. "realtime:public"
      if has_schema(event_config, change.schema) do
        RealtimeWeb.RealtimeChannel.handle_realtime_transaction(schema_topic, change)
      end

      # Special case for notifiying "*"
      if has_schema(event_config, "*") do
        RealtimeWeb.RealtimeChannel.handle_realtime_transaction("#{topic}:*", change)
      end

      # Shout to specific table - e.g. "realtime:public:users"
      if has_table(event_config, change.schema, change.table) do
        RealtimeWeb.RealtimeChannel.handle_realtime_transaction(table_topic, change)
      end

      # Shout to specific columns - e.g. "realtime:public:users.id=eq.2"
      case change.type do
        type when type in ["INSERT", "UPDATE"] ->
          if Map.has_key?(change, :record) do
            Enum.each(change.record, fn {k, v} ->
              should_notify_column = has_column(event_config, change.schema, change.table, k)

              if is_valid_notification_key(v) and should_notify_column do
                eq = "#{table_topic}:#{k}=eq.#{v}"
                RealtimeWeb.RealtimeChannel.handle_realtime_transaction(eq, change)
              end
            end)
          end

        "DELETE" ->
          if Map.has_key?(change, :old_record) do
            Enum.each(change.old_record, fn {k, v} ->
              should_notify_column = has_column(event_config, change.schema, change.table, k)

              if is_valid_notification_key(v) and should_notify_column do
                eq = "#{table_topic}:#{k}=eq.#{v}"
                RealtimeWeb.RealtimeChannel.handle_realtime_transaction(eq, change)
              end
            end)
          end

        "TRUNCATE" ->
          nil
      end
    end
  end

  @doc """
  Determines whether the Realtime config has a specific schema relation
  """
  defp has_schema(config, schema) do
    valid_patterns = ["*", schema]
    Enum.any?(config, fn c -> c.relation in valid_patterns end)
  end

  @doc """
  Determines whether the Realtime config has a specific table relation
  """
  defp has_table(config, schema, table) do
    # Construct an array of valid patterns: "*:*", "public:todos", etc
    valid_patterns =
      for schema_keys <- ["*", schema],
          table_keys <- ["*", table],
          do: "#{schema_keys}:#{table_keys}"

    Enum.any?(config, fn c -> c.relation in valid_patterns end)
  end

  @doc """
  Determines whether the Realtime config has a specific column relation
  """
  defp has_column(config, schema, table, column) do
    # Construct an array of valid patterns: "*:*:*", "public:todos", etc
    valid_patterns =
      for schema_keys <- ["*", schema],
          table_keys <- ["*", table],
          column_keys <- ["*", column],
          do: "#{schema_keys}:#{table_keys}:#{column_keys}"

    Enum.any?(config, fn c -> c.relation in valid_patterns end)
  end

  defp is_valid_notification_key(v) do
    v != nil and v != :unchanged_toast and String.length(v) < 100
  end

  defp notify_connectors(txn) do
    Realtime.Connectors.notify(txn)
  end
end
