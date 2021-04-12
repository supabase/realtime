defmodule Realtime.SubscribersNotification do
  require Logger

  alias Realtime.Adapters.Changes.{
    DeletedRecord,
    NewRecord,
    Transaction,
    TruncatedRelation,
    UpdatedRecord
  }

  alias Realtime.Replication
  alias Realtime.Configuration.Configuration
  alias Realtime.ConfigurationManager
  alias RealtimeWeb.RealtimeChannel

  @topic "realtime"

  def notify(%Replication.State{transaction: {_lsn, %Transaction{changes: [_ | _]}}} = state) do
    {:ok, %Configuration{webhooks: webhooks_config} = config} = ConfigurationManager.get_config()

    txn = notify_subscribers(state, config)
    :ok = Realtime.WebhookConnector.notify(txn, webhooks_config)
    :ok = Realtime.Workflows.Manager.notify(txn)
    :ok = Realtime.Workflows.invoke_transaction_workflows(txn)
  end

  def notify(_txn) do
    :ok
  end

  defp notify_subscribers(
         %Replication.State{
           relations: relations,
           transaction:
             {_lsn,
              %Transaction{changes: [_ | _] = changes, commit_timestamp: commit_timestamp} =
                txn_struct}
         },
         %Configuration{
           realtime: realtime_config,
           webhooks: webhooks_config
         }
       )
       when is_map(relations) and is_list(realtime_config) and is_list(webhooks_config) do
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

    %{
      txn_struct
      | changes:
          Enum.map(changes, fn change_record ->
            {relation_id, _type, _tuple_data, _old_tuple_data} = change_record
            relation = Map.fetch!(relations, relation_id)

            transformed_record = transform_record(change_record, relation, commit_timestamp)
            encoded_record = Jason.encode!(transformed_record)

            %{schema: schema, table: table, type: record_type} = transformed_record

            schema_topic = [@topic, ":", schema] |> IO.iodata_to_binary()
            table_topic = [schema_topic, ":", table] |> IO.iodata_to_binary()

            # Get only the config which includes this event type (INSERT | UPDATE | DELETE | TRUNCATE)
            event_config =
              Enum.filter(realtime_config, fn config ->
                case config do
                  %Realtime.Configuration.Realtime{events: [_ | _] = events} ->
                    record_type in events

                  _ ->
                    false
                end
              end)

            # Shout to specific schema - e.g. "realtime:public"
            if has_schema(event_config, schema) do
              RealtimeChannel.handle_realtime_transaction(
                schema_topic,
                record_type,
                encoded_record
              )
            end

            # Special case for notifiying "*"
            if has_schema(event_config, "*") do
              [@topic, ":*"]
              |> IO.iodata_to_binary()
              |> RealtimeChannel.handle_realtime_transaction(record_type, encoded_record)
            end

            # Shout to specific table - e.g. "realtime:public:users"
            if has_table(event_config, schema, table) do
              RealtimeChannel.handle_realtime_transaction(
                table_topic,
                record_type,
                encoded_record
              )
            end

            # Shout to specific columns - e.g. "realtime:public:users.id=eq.2"
            case record_type do
              type when type in ["INSERT", "UPDATE"] ->
                record = Map.get(transformed_record, :record)

                is_map(record) &&
                  Enum.each(record, fn {k, v} ->
                    should_notify_column = has_column(event_config, schema, table, k)

                    if is_valid_notification_key(v) and should_notify_column do
                      [table_topic, ":", k, "=eq.", v]
                      |> IO.iodata_to_binary()
                      |> RealtimeChannel.handle_realtime_transaction(
                        record_type,
                        encoded_record
                      )
                    end
                  end)

              "DELETE" ->
                old_record = Map.get(transformed_record, :old_record)

                is_map(old_record) &&
                  Enum.each(old_record, fn {k, v} ->
                    should_notify_column = has_column(event_config, schema, table, k)

                    if is_valid_notification_key(v) and should_notify_column do
                      [table_topic, ":", k, "=eq.", v]
                      |> IO.iodata_to_binary()
                      |> RealtimeChannel.handle_realtime_transaction(
                        record_type,
                        encoded_record
                      )
                    end
                  end)

              "TRUNCATE" ->
                nil
            end

            transformed_record
          end)
    }
  end

  defp notify_subscribers(_txn, _config), do: :ok

  defp transform_record(
         {_relation_id, "INSERT" = insert, tuple_data, nil},
         %{columns: columns, namespace: namespace, name: name},
         commit_timestamp
       ) do
    %NewRecord{
      type: insert,
      schema: namespace,
      table: name,
      columns: columns,
      record: Replication.data_tuple_to_map(columns, tuple_data),
      commit_timestamp: commit_timestamp
    }
  end

  defp transform_record(
         {_relation_id, "UPDATE" = update, tuple_data, old_tuple_data},
         %{columns: columns, namespace: namespace, name: name},
         commit_timestamp
       ) do
    %UpdatedRecord{
      type: update,
      schema: namespace,
      table: name,
      columns: columns,
      old_record: Replication.data_tuple_to_map(columns, old_tuple_data),
      record: Replication.data_tuple_to_map(columns, tuple_data),
      commit_timestamp: commit_timestamp
    }
  end

  defp transform_record(
         {_relation_id, "DELETE" = delete, nil, old_tuple_data},
         %{columns: columns, namespace: namespace, name: name},
         commit_timestamp
       ) do
    %DeletedRecord{
      type: delete,
      schema: namespace,
      table: name,
      columns: columns,
      old_record: Realtime.Replication.data_tuple_to_map(columns, old_tuple_data),
      commit_timestamp: commit_timestamp
    }
  end

  defp transform_record(
         {_relation_id, "TRUNCATE" = truncate, nil, nil},
         %{namespace: namespace, name: name},
         commit_timestamp
       ) do
    %TruncatedRelation{
      type: truncate,
      schema: namespace,
      table: name,
      commit_timestamp: commit_timestamp
    }
  end

  defp transform_record(change_record, _relation, _commit_timestamp), do: change_record

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
