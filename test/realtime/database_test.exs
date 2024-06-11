defmodule Realtime.DatabaseTest do
  use Realtime.DataCase, async: false
  # async: false due to the deletion of the replication slot potentially affecting other tests
  doctest Realtime.Database
  alias Realtime.Database

  describe "replication_slot_teardown/1" do
    setup do
      %{tenant: tenant_fixture()}
    end

    test "removes replication slots with the realtime prefix", %{tenant: tenant} do
      [extension] = tenant.extensions
      args = Map.put(extension.settings, "id", random_string())

      pid =
        start_supervised!({Extensions.PostgresCdcStream.Replication, args}, restart: :transient)

      {:ok, conn} = Database.check_tenant_connection(tenant, "realtime_test")
      # Check replication slot was created
      assert %{rows: [["supabase_realtime_replication_slot"]]} =
               Postgrex.query!(conn, "SELECT slot_name FROM pg_replication_slots", [])

      # Kill connections to database
      Extensions.PostgresCdcStream.Replication.stop(pid)
      Database.replication_slot_teardown(tenant)

      assert %{rows: []} = Postgrex.query!(conn, "SELECT slot_name FROM pg_replication_slots", [])
    end
  end
end
