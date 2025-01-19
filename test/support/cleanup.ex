defmodule Cleanup do
  def ensure_no_replication_slot(attempts \\ 5)
  def ensure_no_replication_slot(0), do: raise("Replication slot teardown failed")

  def ensure_no_replication_slot(attempts) do
    {:ok, conn} =
      Postgrex.start_link(
        hostname: "localhost",
        port: 5433,
        database: "postgres",
        username: "supabase_admin",
        password: "postgres"
      )

    case Postgrex.query(conn, "SELECT active_pid, slot_name FROM pg_replication_slots", []) do
      {:ok, %{rows: []}} ->
        :ok

      {:ok, %{rows: rows}} ->
        Enum.each(rows, fn [pid, slot_name] ->
          Postgrex.query(conn, "select pg_terminate_backend($1) ", [pid])
          Postgrex.query(conn, "select pg_drop_replication_slot($1)", [slot_name])
        end)

      {:error, _} ->
        Process.sleep(1000)
        ensure_no_replication_slot(attempts - 1)
    end
  end
end
