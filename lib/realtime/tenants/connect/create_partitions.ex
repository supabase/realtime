defmodule Realtime.Tenants.Connect.CreatePartitions do
  alias Realtime.Database

  @behaviour Realtime.Tenants.Connect.Piper

  @impl true
  def run(%{db_conn_pid: db_conn_pid} = acc) do
    today = Date.utc_today()
    yesterday = Date.add(today, -1)
    tomorrow = Date.add(today, 1)

    dates = [yesterday, today, tomorrow]

    Enum.each(dates, fn date ->
      partition_name = "messages_#{date |> Date.to_iso8601() |> String.replace("-", "_")}"
      start_timestamp = Date.to_string(date)
      end_timestamp = Date.to_string(Date.add(date, 1))

      Database.transaction(db_conn_pid, fn conn ->
        Postgrex.query(
          conn,
          """
          CREATE TABLE IF NOT EXISTS realtime.#{partition_name}
          PARTITION OF realtime.messages
          FOR VALUES FROM ('#{start_timestamp}') TO ('#{end_timestamp}');
          """,
          []
        )
      end)
    end)

    {:ok, acc}
  end
end
