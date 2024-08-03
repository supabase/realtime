defmodule Realtime.DatabaseTest do
  # async: false due to the deletion of the replication slot potentially affecting other tests
  use Realtime.DataCase, async: false

  import ExUnit.CaptureLog
  alias Realtime.Database
  doctest Realtime.Database

  describe "replication_slot_teardown/1" do
    setup do
      %{tenant: tenant_fixture()}
    end

    test "removes replication slots with the realtime prefix", %{tenant: tenant} do
      [extension] = tenant.extensions
      args = Map.put(extension.settings, "id", random_string())

      pid =
        start_supervised!({Extensions.PostgresCdcStream.Replication, args}, restart: :transient)

      {:ok, conn} = Database.connect(tenant, "realtime_test", 1)
      # Check replication slot was created
      assert %{rows: [["supabase_realtime_replication_slot"]]} =
               Postgrex.query!(conn, "SELECT slot_name FROM pg_replication_slots", [])

      # Kill connections to database
      Extensions.PostgresCdcStream.Replication.stop(pid)
      Database.replication_slot_teardown(tenant)

      assert %{rows: []} = Postgrex.query!(conn, "SELECT slot_name FROM pg_replication_slots", [])
    end
  end

  describe "transaction/1" do
    setup do
      tenant = tenant_fixture()
      {:ok, db_conn} = Database.connect(tenant, "realtime_test", 1, :stop)
      %{db_conn: db_conn}
    end

    test "on error, captures the error", %{db_conn: db_conn} do
      assert capture_log(fn ->
               Task.start(fn ->
                 Database.transaction(db_conn, fn conn ->
                   Postgrex.query!(conn, "SELECT pg_sleep(14)", [])
                 end)
               end)

               for _ <- 0..10 do
                 Task.start(fn ->
                   Database.transaction(db_conn, fn conn ->
                     Postgrex.query!(conn, "SELECT pg_sleep(5)", [])
                   end)
                 end)
               end

               :timer.sleep(15000)
             end) =~ "ErrorExecutingTransaction"
    end
  end
end
