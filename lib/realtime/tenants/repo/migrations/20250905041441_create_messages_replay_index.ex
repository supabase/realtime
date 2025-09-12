defmodule Realtime.Tenants.Migrations.CreateMessagesReplayIndex do
  @moduledoc false

  use Ecto.Migration

  def change do
    # Drop all existing partitions
    # Create index
    # Create partitions back again

    %{rows: tables} =
      repo().query!(
        """
        SELECT child.relname
        FROM pg_inherits
        JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
        JOIN pg_class child ON pg_inherits.inhrelid = child.oid
        JOIN pg_namespace nmsp_parent ON nmsp_parent.oid = parent.relnamespace
        JOIN pg_namespace nmsp_child ON nmsp_child.oid = child.relnamespace
        WHERE parent.relname = 'messages'
        AND nmsp_child.nspname = 'realtime'
        """,
        []
      )

    tables
    |> Enum.filter(fn
      ["messages_" <> _date] -> true
      _ -> false
    end)
    |> Enum.each(fn [table] ->
      drop_if_exists table(table)
    end)

    create_if_not_exists index(:messages, [{:desc, :inserted_at}, :topic, :private])

    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    future = Date.add(today, 3)

    dates = Date.range(yesterday, future)

    Enum.each(dates, fn date ->
      partition_name = "messages_#{date |> Date.to_iso8601() |> String.replace("-", "_")}"
      start_timestamp = Date.to_string(date)
      end_timestamp = Date.to_string(Date.add(date, 1))

      execute """
      CREATE TABLE IF NOT EXISTS realtime.#{partition_name}
      PARTITION OF realtime.messages
      FOR VALUES FROM ('#{start_timestamp}') TO ('#{end_timestamp}');
      """
    end)
  end
end
