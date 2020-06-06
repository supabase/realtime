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
    for raw_change <- txn.changes do
      change = Map.put(raw_change, :commit_timestamp, txn.commit_timestamp)
      # Logger.debug inspect(change, pretty: true)

      # Shout to anyone listening on the open realtime channel - e.g. "realtime:*"
      topic = "realtime"
      RealtimeWeb.RealtimeChannel.handle_realtime_transaction(topic <> ":*", change)

      # Shout to specific schema - e.g. "realtime:public"
      schema_topic = topic <> ":" <> change.schema
      Logger.debug inspect(schema_topic)
      RealtimeWeb.RealtimeChannel.handle_realtime_transaction(schema_topic, change)

      # Shout to specific table - e.g. "realtime:public:users"
      table_topic = schema_topic <> ":" <> change.table
      Logger.debug inspect(table_topic)
      RealtimeWeb.RealtimeChannel.handle_realtime_transaction(table_topic, change)

      # Shout to specific columns - e.g. "realtime:public:users.id=eq.2"
      if Map.has_key?(change, :record) do
        Enum.each change.record, fn {k, v} ->
          if v != nil and v != :unchanged_toast do
            eq = table_topic <> ":" <> k <> "=eq." <> v
            Logger.debug inspect(eq)
            RealtimeWeb.RealtimeChannel.handle_realtime_transaction(eq, change)
          end
        end
      end
    end
  end

  defp notify_connectors(txn) do
    Realtime.Connectors.notify(txn)
  end

end
