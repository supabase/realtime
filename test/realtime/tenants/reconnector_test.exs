defmodule Realtime.Tenants.ReconnectorTest do
  use Realtime.DataCase, async: true
  use Mimic

  setup :set_mimic_from_context

  import ExUnit.CaptureLog

  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Reconnector
  alias Realtime.UsersCounter
  alias RealtimeWeb.Endpoint

  setup do
    tenant = TestTenantDb.checkout_tenant(run_migrations: true)

    %{tenant: tenant}
  end

  describe "periodic reconnect check" do
    test "restarts Connect when this node still has connected users", %{tenant: tenant} do
      reconnector = start_reconnector(tenant)

      assert {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      pid = Connect.whereis(tenant.external_id)

      # The test process is the user, so it stops counting once the test ends.
      UsersCounter.add(self(), tenant.external_id)

      Endpoint.subscribe(Connect.syn_topic(tenant.external_id))

      Process.exit(pid, :kill)
      assert_receive %{event: "connect_down"}, 5000

      send(reconnector, :check)

      assert_receive %{event: "ready", payload: %{pid: new_pid}}, 5000
      assert new_pid != pid
      assert Connect.whereis(tenant.external_id) == new_pid
    end

    test "does not restart Connect when this node has no connected users", %{tenant: tenant} do
      reconnector = start_reconnector(tenant)

      assert {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      pid = Connect.whereis(tenant.external_id)

      Endpoint.subscribe(Connect.syn_topic(tenant.external_id))

      Process.exit(pid, :kill)
      assert_receive %{event: "connect_down"}, 5000

      send(reconnector, :check)

      refute_receive %{event: "ready"}, 500
      refute Connect.whereis(tenant.external_id)
    end

    test "logs a warning when Connect had an RPC error", %{tenant: tenant} do
      %{external_id: tenant_id} = tenant
      reconnector = start_reconnector(tenant)

      UsersCounter.add(self(), tenant_id)

      test_pid = self()

      # Holds the reconnect task until it is monitored, so its exit reason can be asserted
      stub(Connect, :lookup_or_start_connection, fn ^tenant_id ->
        send(test_pid, {:reconnecting, self()})
        receive do: (:continue -> {:error, :rpc_error, :timeout})
      end)

      allow(Connect, self(), reconnector)
      send(reconnector, :check)

      assert_receive {:reconnecting, task_pid}, 5000
      ref = Process.monitor(task_pid)

      log =
        capture_log(fn ->
          send(task_pid, :continue)
          assert_receive {:DOWN, ^ref, :process, ^task_pid, :normal}
        end)

      assert log =~ "Reconnector could not restart connection for #{tenant_id}: :timeout"
    end
  end

  # Reconnector's `:check` restarts `Connect` for every tenant in `UsersCounter.local_tenant_counts/0`
  # that has none, which includes the tenants of other tests running concurrently. Restarting a
  # `Connect` their test already stopped leaks it: it stays on a database that is handed to later
  # tests and recreates its replication slot there. So we only show it this test's tenant to isolate it.
  # This also keeps the test async.
  defp start_reconnector(%{external_id: tenant_id}) do
    stub(UsersCounter, :local_tenant_counts, fn ->
      UsersCounter |> call_original(:local_tenant_counts, []) |> Map.take([tenant_id])
    end)

    {:ok, reconnector} = Reconnector.start_link([])
    allow(UsersCounter, self(), reconnector)
    reconnector
  end
end
