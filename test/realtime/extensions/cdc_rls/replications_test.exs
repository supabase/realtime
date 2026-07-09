defmodule Realtime.Extensions.PostgresCdcRls.ReplicationsTest do
  use Realtime.DataCase, async: true

  alias Extensions.PostgresCdcRls.Replications
  alias Extensions.PostgresCdcRls.Subscriptions
  alias Realtime.Database

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, conn} = Database.connect(tenant, "realtime_rls", :stop)
    %{conn: conn}
  end

  describe "terminate_backend/2" do
    test "returns slot_not_found when slot does not exist", %{conn: conn} do
      assert {:error, :slot_not_found} =
               Replications.terminate_backend(conn, "nonexistent_slot_#{:rand.uniform(999_999)}")
    end

    test "returns slot_not_found when slot exists but has no active backend", %{conn: conn} do
      slot_name = "test_inactive_slot_#{:rand.uniform(999_999)}"

      Postgrex.query!(conn, "SELECT pg_create_logical_replication_slot($1, 'wal2json')", [slot_name])

      try do
        # No replication session is reading from it, so active_pid is nil
        assert {:error, :slot_not_found} = Replications.terminate_backend(conn, slot_name)
      after
        Postgrex.query(conn, "SELECT pg_drop_replication_slot($1)", [slot_name])
      end
    end
  end

  describe "get_pg_stat_activity_diff/2" do
    test "returns error when pid is not in pg_stat_activity", %{conn: conn} do
      assert {:error, :pid_not_found} = Replications.get_pg_stat_activity_diff(conn, 0)
    end

    test "returns diff when pid is found in pg_stat_activity", %{conn: conn} do
      # Get the PID of the current connection from pg_stat_activity
      %{rows: [[db_pid]]} = Postgrex.query!(conn, "SELECT pg_backend_pid()", [])

      # Update the application name so we can find this connection
      Postgrex.query!(conn, "SET application_name = 'realtime_rls'", [])

      assert {:ok, diff} = Replications.get_pg_stat_activity_diff(conn, db_pid)
      assert is_integer(diff)
    end
  end

  describe "list_changes/5" do
    test "returns rows from the publication slot", %{conn: conn} do
      slot_name = "test_list_slot_#{:rand.uniform(999_999)}"
      publication = "supabase_realtime_test"

      Postgrex.query!(conn, "SELECT pg_create_logical_replication_slot($1, 'wal2json')", [slot_name])

      try do
        assert {:ok, %Postgrex.Result{columns: columns}} =
                 Replications.list_changes(conn, slot_name, publication, 100, 1_048_576)

        assert "type" in columns
      after
        Postgrex.query(conn, "SELECT pg_drop_replication_slot($1)", [slot_name])
      end
    end
  end

  describe "drop_replication_slot/2" do
    test "returns slot_not_found when slot does not exist", %{conn: conn} do
      assert {:error, :slot_not_found} =
               Replications.drop_replication_slot(conn, "nonexistent_slot_#{:rand.uniform(999_999)}")
    end

    test "drops an existing inactive slot", %{conn: conn} do
      slot_name = "test_drop_slot_#{:rand.uniform(999_999)}"
      Postgrex.query!(conn, "SELECT pg_create_logical_replication_slot($1, 'wal2json')", [slot_name])

      assert {:ok, :dropped} = Replications.drop_replication_slot(conn, slot_name)

      %{rows: [[count]]} =
        Postgrex.query!(conn, "SELECT count(*)::int FROM pg_replication_slots WHERE slot_name = $1", [slot_name])

      assert count == 0
    end
  end

  describe "prepare_replication/2" do
    test "creates a replication slot when it does not exist", %{conn: conn} do
      slot_name = "test_prep_slot_#{:rand.uniform(999_999)}"
      assert {:ok, %Postgrex.Result{}} = Replications.prepare_replication(conn, slot_name)
    end

    test "is idempotent when slot already exists", %{conn: conn} do
      slot_name = "test_idempotent_slot_#{:rand.uniform(999_999)}"
      assert {:ok, _} = Replications.prepare_replication(conn, slot_name)
      assert {:ok, _} = Replications.prepare_replication(conn, slot_name)
    end
  end

  describe "list_changes for schemas and tables with special characters" do
    setup %{conn: conn} do
      {:ok, _} = Integrations.setup_postgres_changes(conn)
      :ok
    end

    defp run_list_changes(conn, schema, table) do
      pub = "supabase_realtime_test"
      slot = "lc_#{:rand.uniform(9_999_999)}"

      # quote identifiers
      %{rows: [[quoted_schema, qualified]]} =
        Postgrex.query!(
          conn,
          "SELECT format('%I', $1::text), format('%I.%I', $1::text, $2::text)",
          [schema, table]
        )

      Postgrex.query!(conn, "CREATE SCHEMA IF NOT EXISTS #{quoted_schema}", [])
      Postgrex.query!(conn, "DROP TABLE IF EXISTS #{qualified}", [])
      Postgrex.query!(conn, "CREATE TABLE #{qualified} (name text PRIMARY KEY)", [])
      Postgrex.query!(conn, "GRANT ALL ON TABLE #{qualified} TO anon", [])
      Postgrex.query!(conn, "GRANT ALL ON TABLE #{qualified} TO authenticated", [])

      {:ok, _} = Replications.prepare_replication(conn, slot)

      {:ok, sub_params} =
        Subscriptions.parse_subscription_params(%{"schema" => schema, "table" => table})

      params_list = [
        %{claims: %{"role" => "anon"}, id: Ecto.UUID.generate(), subscription_params: sub_params}
      ]

      assert {:ok, _} = Subscriptions.create(conn, pub, params_list, self(), self())

      Postgrex.query!(conn, "INSERT INTO #{qualified} VALUES ('list_changes_test')", [])

      try do
        Replications.list_changes(conn, slot, pub, 100, 1_048_576)
      after
        Postgrex.query(conn, "SELECT pg_drop_replication_slot($1)", [slot])
        Postgrex.query(conn, "DROP TABLE IF EXISTS #{qualified}", [])

        if schema != "public",
          do: Postgrex.query(conn, "DROP SCHEMA IF EXISTS #{quoted_schema} CASCADE", [])
      end
    end

    defp insert_row_for({:ok, %Postgrex.Result{rows: rows}}, expected_table) do
      Enum.find(rows, fn
        ["INSERT", _schema, ^expected_table, _cols, record | _] ->
          record == ~s|{"name": "list_changes_test"}|

        _ ->
          false
      end)
    end

    test "space", %{conn: conn} do
      result = run_list_changes(conn, "public", "my table")
      assert insert_row_for(result, "my table")
    end

    test "comma", %{conn: conn} do
      result = run_list_changes(conn, "public", "my,table")
      assert insert_row_for(result, "my,table")
    end

    test "dot", %{conn: conn} do
      result = run_list_changes(conn, "public", "my.table")
      assert insert_row_for(result, "my.table")
    end

    test "tab", %{conn: conn} do
      result = run_list_changes(conn, "public", "tab\there")
      assert insert_row_for(result, "tab\there")
    end

    test "double-quote", %{conn: conn} do
      result = run_list_changes(conn, "public", ~s|my"table|)
      assert insert_row_for(result, ~s|my"table|)
    end

    test "backslash", %{conn: conn} do
      result = run_list_changes(conn, "public", "my\\table")
      assert insert_row_for(result, "my\\table")
    end

    test "emoji", %{conn: conn} do
      result = run_list_changes(conn, "public", "[my_table] 🟠")
      assert insert_row_for(result, "[my_table] 🟠")
    end

    test "schema and table with spaces", %{conn: conn} do
      result = run_list_changes(conn, "my schema", "my table")
      assert insert_row_for(result, "my table")
    end

    test "schema and table with special cases", %{conn: conn} do
      result = run_list_changes(conn, ~s|test "schema|, ~s|test " with 'quotes'|)
      assert insert_row_for(result, ~s|test " with 'quotes'|)
    end
  end
end
