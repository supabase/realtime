defmodule Realtime.Tenants.ReconnectorTest do
  use Realtime.DataCase, async: true

  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Reconnector
  alias Realtime.UsersCounter
  alias RealtimeWeb.Endpoint

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)

    %{tenant: tenant}
  end

  describe "periodic reconnect check" do
    test "restarts Connect when this node still has connected users", %{tenant: tenant} do
      {:ok, reconnector} = Reconnector.start_link([])

      assert {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      pid = Connect.whereis(tenant.external_id)

      user_pid = spawn(fn -> Process.sleep(:infinity) end)
      UsersCounter.add(user_pid, tenant.external_id)

      Endpoint.subscribe(Connect.syn_topic(tenant.external_id))

      Process.exit(pid, :kill)
      assert_receive %{event: "connect_down"}, 5000

      send(reconnector, :check)

      assert_receive %{event: "ready", payload: %{pid: new_pid}}, 5000
      assert new_pid != pid
      assert Connect.whereis(tenant.external_id) == new_pid
    end

    test "does not restart Connect when this node has no connected users", %{tenant: tenant} do
      {:ok, reconnector} = Reconnector.start_link([])

      assert {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      pid = Connect.whereis(tenant.external_id)

      Endpoint.subscribe(Connect.syn_topic(tenant.external_id))

      Process.exit(pid, :kill)
      assert_receive %{event: "connect_down"}, 5000

      send(reconnector, :check)

      refute_receive %{event: "ready"}, 500
      refute Connect.whereis(tenant.external_id)
    end
  end
end
