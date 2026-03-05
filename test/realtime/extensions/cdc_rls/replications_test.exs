defmodule Realtime.Extensions.PostgresCdcRls.ReplicationsTest do
  use Realtime.DataCase, async: true

  alias Extensions.PostgresCdcRls.Replications
  alias Realtime.Database

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, conn} = Database.connect(tenant, "realtime_rls", :stop)
    %{conn: conn}
  end

  describe "terminate_backend/2" do
    test "returns slot_not_found when slot does not exist", %{conn: conn} do
      assert {:error, :slot_not_found} = Replications.terminate_backend(conn, "nonexistent_slot_#{:rand.uniform(999_999)}")
    end

    test "returns slot_not_found when slot exists but has no active backend", %{conn: conn} do
      slot_name = "test_inactive_slot_#{:rand.uniform(999_999)}"

      # Create a permanent slot — no replication session is reading from it, so active_pid is nil
      Postgrex.query!(conn, "SELECT pg_create_logical_replication_slot($1, 'wal2json')", [slot_name])

      assert {:error, :slot_not_found} = Replications.terminate_backend(conn, slot_name)

      Postgrex.query!(conn, "SELECT pg_drop_replication_slot($1)", [slot_name])
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
end
