defmodule Realtime.Tenants.ReconnectorTest do
  # Async false since we're spawning real Connect processes and manipulating Census/:syn state
  use Realtime.DataCase, async: false

  alias Realtime.Tenants.Connect
  alias Realtime.Tenants.Reconnector
  alias Realtime.UsersCounter
  alias RealtimeWeb.Endpoint

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)

    %{tenant: tenant}
  end

  defp assert_process_down(pid, timeout \\ 100) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, timeout
  end

  describe "handle_syn_event/4" do
    test "notifies the given pid to check for a reconnect" do
      Reconnector.handle_syn_event([:syn, Connect, :unregistered], %{}, %{name: "a-tenant"}, self())

      assert_receive {:check_reconnect, "a-tenant"}
    end
  end

  describe "reconnect on Connect crash" do
    test "restarts Connect when this node still has connected users", %{tenant: tenant} do
      assert {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      pid = Connect.whereis(tenant.external_id)

      user_pid = spawn(fn -> Process.sleep(:infinity) end)
      UsersCounter.add(user_pid, tenant.external_id)

      Endpoint.subscribe(Connect.syn_topic(tenant.external_id))

      Process.exit(pid, :kill)
      assert_process_down(pid)

      assert_receive %{event: "ready", payload: %{pid: new_pid}}, 5000
      assert new_pid != pid
      assert Connect.whereis(tenant.external_id) == new_pid
    end

    test "does not restart Connect when this node has no connected users", %{tenant: tenant} do
      assert {:ok, _} = Connect.lookup_or_start_connection(tenant.external_id)
      pid = Connect.whereis(tenant.external_id)

      Endpoint.subscribe(Connect.syn_topic(tenant.external_id))

      Process.exit(pid, :kill)
      assert_process_down(pid)

      refute_receive %{event: "ready"}, 500
      refute Connect.whereis(tenant.external_id)
    after
      Endpoint.unsubscribe(Connect.syn_topic(tenant.external_id))
    end
  end
end
