defmodule Ewalrus.SubscribersNotification do
  require Logger

  @topic "realtime"

  # def notify(%Transaction{changes: changes} = txn) when is_list(changes) do
  #   {:ok, %Configuration{realtime: realtime_config, webhooks: webhooks_config}} =
  #     ConfigurationManager.get_config()

  #   :ok = notify_subscribers(changes, realtime_config)
  #   :ok = Realtime.WebhookConnector.notify(txn, webhooks_config)
  # end

  # def notify(changes) when is_list(changes) do
  #   {:ok, %Configuration{realtime: realtime_config}} = ConfigurationManager.get_config()
  #   :ok = notify_subscribers(changes, realtime_config)
  # end

  # def notify(_) do
  #   :ok
  # end

  def broadcast_change(_topic, %{subscription_ids: subs_id} = change, scope) do
    payload =
      Map.filter(change, fn {key, _} ->
        !Enum.member?([:is_rls_enabled, :subscription_ids], key)
      end)

    :syn.members(Ewalrus.Subscribers, scope)
    |> Enum.each(fn {pid, bin_id} ->
      if MapSet.member?(subs_id, bin_id) do
        Logger.debug(
          "Sent event, #{inspect([pid: pid, id: UUID.binary_to_string!(bin_id), msd: change], pretty: true)}"
        )

        send(pid, {:event, payload})
      end
    end)
  end

  def notify_subscribers([_ | _] = changes, id) do
    Enum.each(changes, fn change ->
      case change do
        %{schema: schema, table: table, type: type}
        when is_binary(schema) and is_binary(table) and is_binary(type) ->
          schema_topic = "#{@topic}:#{schema}"
          table_topic = "#{schema_topic}:#{table}"

          # Get only the config which includes this event type (INSERT | UPDATE | DELETE | TRUNCATE)
          # TODO: implement
          event_config = %{}
          # Enum.filter(realtime_config, fn config ->
          #   case config do
          #     %Realtime.Configuration.Realtime{events: [_ | _] = events} -> type in events
          #     _ -> false
          #   end
          # end)

          # Shout to specific schema - e.g. "realtime:public"
          if has_schema(event_config, schema) do
            broadcast_change(schema_topic, change, id)
          end

          # Special case for notifiying "*"
          # if has_schema(event_config, "*") do
          #   "#{@topic}:*"
          #   |> broadcast_change(change)
          # end

          # Shout to specific table - e.g. "realtime:public:users"
          if has_table(event_config, schema, table) do
            broadcast_change(table_topic, change, id)
          end

          # Shout to specific columns - e.g. "realtime:public:users.id=eq.2"
          if type in ["INSERT", "UPDATE", "DELETE"] do
            record_key = if type == "DELETE", do: :old_record, else: :record

            record = Map.get(change, record_key)

            is_map(record) &&
              Enum.each(record, fn {k, v} ->
                with true <- is_notification_key_valid(v),
                     {:ok, stringified_v} <- stringify_value(v),
                     true <- is_notification_key_length_valid(stringified_v),
                     true <- has_column(event_config, schema, table, k) do
                  "#{table_topic}:#{k}=eq.#{stringified_v}"
                  |> broadcast_change(change, id)
                end
              end)
          end

        _ ->
          nil
      end
    end)
  end

  def notify_subscribers(_, _), do: :ok
  # defp notify_subscribers(_, _config), do: :ok

  # TODO: implement
  defp has_schema(_config, _schema) do
    # Determines whether the Realtime config has a specific schema relation
    # valid_patterns = ["*", schema]
    # Enum.any?(config, fn c -> c.relation in valid_patterns end)
    true
  end

  defp has_table(config, schema, table) do
    # Determines whether the Realtime config has a specific table relation
    # Construct an array of valid patterns: "*:*", "public:todos", etc
    valid_patterns =
      for schema_keys <- ["*", schema],
          table_keys <- ["*", table],
          do: "#{schema_keys}:#{table_keys}"

    Enum.any?(config, fn c -> c.relation in valid_patterns end)
  end

  defp has_column(config, schema, table, column) do
    # Determines whether the Realtime config has a specific column relation
    # Construct an array of valid patterns: "*:*:*", "public:todos", etc
    valid_patterns =
      for schema_keys <- ["*", schema],
          table_keys <- ["*", table],
          column_keys <- ["*", column],
          do: "#{schema_keys}:#{table_keys}:#{column_keys}"

    Enum.any?(config, fn c -> c.relation in valid_patterns end)
  end

  defp is_notification_key_valid(v) do
    v != nil and v != :unchanged_toast
  end

  defp stringify_value(v) when is_binary(v), do: {:ok, v}
  defp stringify_value(v), do: Jason.encode(v)

  defp is_notification_key_length_valid(v), do: String.length(v) < 100
end
