defmodule Extensions.PostgresCdcRls.ReplicationsTest do
  use Realtime.DataCase, async: false

  alias Extensions.PostgresCdcRls.Replications
  alias Extensions.PostgresCdcRls.Subscriptions
  alias Realtime.Database

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, conn} = Database.connect(tenant, "realtime_rls", :stop)
    Integrations.setup_postgres_changes(conn)
    %{conn: conn, tenant: tenant}
  end

  defp drop_slot_on_exit(tenant, slot_name) do
    on_exit(fn ->
      {:ok, conn} = Database.connect(tenant, "realtime_rls", :stop)
      Postgrex.query(conn, "select pg_drop_replication_slot($1)", [slot_name])
      GenServer.stop(conn)
    end)
  end

  describe "prepare_replication/2" do
    test "creates a replication slot", %{conn: conn, tenant: tenant} do
      slot_name = "test_slot_#{System.unique_integer([:positive])}"
      drop_slot_on_exit(tenant, slot_name)

      assert {:ok, %Postgrex.Result{}} = Replications.prepare_replication(conn, slot_name)

      assert {:ok, %Postgrex.Result{num_rows: 1}} =
               Postgrex.query(conn, "select 1 from pg_replication_slots where slot_name = $1", [slot_name])
    end

    test "is idempotent when slot already exists", %{conn: conn, tenant: tenant} do
      slot_name = "test_slot_#{System.unique_integer([:positive])}"
      drop_slot_on_exit(tenant, slot_name)

      assert {:ok, _} = Replications.prepare_replication(conn, slot_name)
      assert {:ok, _} = Replications.prepare_replication(conn, slot_name)
    end
  end

  describe "terminate_backend/2" do
    test "returns slot_not_found when slot does not exist", %{conn: conn} do
      assert {:error, :slot_not_found} = Replications.terminate_backend(conn, "nonexistent_slot")
    end

    test "returns error when connection is in a failed transaction", %{tenant: tenant} do
      {:ok, bad_conn} = Realtime.Database.connect(tenant, "realtime_rls", :stop)

      Postgrex.transaction(bad_conn, fn trans_conn ->
        # Put the transaction in failed state
        Postgrex.query(trans_conn, "SELECT 1/0", [])
        # Subsequent queries return {:error, %Postgrex.Error{}} due to failed transaction
        assert {:error, %Postgrex.Error{}} = Replications.terminate_backend(trans_conn, "any_slot")
        # Return error to trigger rollback
        {:error, :rollback}
      end)

      GenServer.stop(bad_conn)
    end

    test "returns slot_not_found when slot exists but has no active backend", %{conn: conn, tenant: tenant} do
      slot_name = "test_slot_#{System.unique_integer([:positive])}"
      drop_slot_on_exit(tenant, slot_name)

      # Use a permanent (non-temporary) slot via a separate connection to avoid
      # connection state issues that temporary slots cause on the same connection
      {:ok, slot_conn} = Realtime.Database.connect(tenant, "realtime_rls", :stop)
      Postgrex.query!(slot_conn, "select pg_create_logical_replication_slot($1, 'pgoutput')", [slot_name])
      GenServer.stop(slot_conn)

      assert {:error, :slot_not_found} = Replications.terminate_backend(conn, slot_name)
    end
  end

  describe "get_pg_stat_activity_diff/2" do
    test "returns error when pid is not in pg_stat_activity", %{conn: conn} do
      assert {:error, :pid_not_found} = Replications.get_pg_stat_activity_diff(conn, 0)
    end

    test "returns diff when pid is found in pg_stat_activity", %{conn: conn} do
      {:ok, %Postgrex.Result{rows: [[backend_pid]]}} = Postgrex.query(conn, "SELECT pg_backend_pid()", [])

      result = Replications.get_pg_stat_activity_diff(conn, backend_pid)

      assert {:ok, diff} = result
      assert is_integer(diff)
    end
  end

  describe "list_changes/5" do
    @publication "supabase_realtime_test"

    test "slot empty: returns only the sentinel row with slot_changes_count of 0", %{conn: conn, tenant: tenant} do
      slot_name = "test_slot_#{System.unique_integer([:positive])}"
      drop_slot_on_exit(tenant, slot_name)

      {:ok, _} = Replications.prepare_replication(conn, slot_name)

      assert {:ok, %Postgrex.Result{rows: rows}} =
               Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)

      assert [sentinel] = rows
      [nil, nil, nil, "[]", "{}", "{}", nil, nil, nil, slot_changes_count] = sentinel
      assert slot_changes_count == 0
    end

    test "slot has changes visible to subscriber: returns real row and slot_changes_count of 1", %{
      conn: conn,
      tenant: tenant
    } do
      slot_name = "test_slot_#{System.unique_integer([:positive])}"
      drop_slot_on_exit(tenant, slot_name)

      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"event" => "*", "schema" => "public", "table" => "test"})

      Subscriptions.create(
        conn,
        @publication,
        [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}],
        self(),
        self()
      )

      {:ok, _} = Replications.prepare_replication(conn, slot_name)

      Postgrex.query!(conn, "INSERT INTO public.test (details) VALUES ('hello')", [])

      assert {:ok, %Postgrex.Result{rows: rows}} =
               Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)

      assert [row] = rows

      assert [
               "INSERT",
               "public",
               "test",
               _columns,
               _record,
               _old_record,
               _commit_timestamp,
               _sub_ids,
               _errors,
               slot_changes_count
             ] = row

      assert slot_changes_count == 1
    end

    test "slot has changes but subscriber does not match the INSERT: returns only the sentinel row with slot_changes_count of 1",
         %{
           conn: conn,
           tenant: tenant
         } do
      slot_name = "test_slot_#{System.unique_integer([:positive])}"
      drop_slot_on_exit(tenant, slot_name)

      {:ok, subscription_params} =
        Subscriptions.parse_subscription_params(%{"event" => "UPDATE", "schema" => "public", "table" => "test"})

      Subscriptions.create(
        conn,
        @publication,
        [%{claims: %{"role" => "anon"}, id: UUID.uuid1(), subscription_params: subscription_params}],
        self(),
        self()
      )

      {:ok, _} = Replications.prepare_replication(conn, slot_name)

      Postgrex.query!(conn, "INSERT INTO public.test (details) VALUES ('hello')", [])

      assert {:ok, %Postgrex.Result{rows: rows}} =
               Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)

      assert [sentinel] = rows
      [nil, nil, nil, "[]", "{}", "{}", nil, nil, nil, slot_changes_count] = sentinel
      assert slot_changes_count == 1
    end

    test "slot has changes but no subscribers: returns only the sentinel row with slot_changes_count of 1", %{
      conn: conn,
      tenant: tenant
    } do
      slot_name = "test_slot_#{System.unique_integer([:positive])}"
      drop_slot_on_exit(tenant, slot_name)

      {:ok, _} = Replications.prepare_replication(conn, slot_name)

      Postgrex.query!(conn, "INSERT INTO public.test (details) VALUES ('hello'), ('hithere')", [])

      assert {:ok, %Postgrex.Result{rows: rows}} =
               Replications.list_changes(conn, slot_name, @publication, 100, 1_048_576)

      assert [sentinel] = rows
      [nil, nil, nil, "[]", "{}", "{}", nil, nil, nil, slot_changes_count] = sentinel
      assert slot_changes_count == 2
    end
  end
end
