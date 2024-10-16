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

    @tag skip: "tests too flaky at the moment"
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

    test "handles transaction errors", %{db_conn: db_conn} do
      assert {:error, %DBConnection.ConnectionError{reason: :error}} =
               Database.transaction(db_conn, fn conn ->
                 Postgrex.query!(conn, "select pg_terminate_backend(pg_backend_pid())", [])
               end)
    end

    test "on checkout error, handles raised exception as an error", %{db_conn: db_conn} do
      assert capture_log(fn ->
               Task.start(fn ->
                 Database.transaction(db_conn, fn conn ->
                   Postgrex.query!(conn, "SELECT pg_sleep(14)", [])
                 end)
               end)

               assert {:error, %DBConnection.ConnectionError{reason: :queue_timeout}} =
                        Task.async(fn ->
                          Database.transaction(db_conn, fn conn ->
                            Postgrex.query!(conn, "SELECT pg_sleep(5)", [])
                          end)
                        end)
                        |> Task.await(15000)
             end) =~ "ErrorExecutingTransaction"
    end
  end
end
