defmodule Realtime.Integration.PresenceNodeLossTest do
  # Starts and stops peer nodes with Clustered, so the tests cannot run at the same time as other
  # tests.
  #
  # The Rollcall mode removes the entries of a node that leaves the cluster. The tests assert how
  # the Rollcall tracker does this, so they run in the Rollcall mode only.
  use RealtimeWeb.ConnCase, async: false

  alias Phoenix.Socket.Message

  @moduletag :capture_log
  @timeout 8_000

  setup do
    tenant = TestTenantDb.checkout_tenant_unboxed(run_migrations: true)
    %{tenant: tenant, topic: "realtime:#{random_string()}"}
  end

  describe "a node that is killed" do
    # The node sends no goodbye. The other nodes drop its entries after the silence threshold.
    test "loses its entries on the other nodes", %{tenant: tenant, topic: topic} do
      [node_a] = Clustered.start_peers([:rollcall_a])
      :ok = ClusterPresence.set_presence_mode(tenant, :rollcall, [node(), node_a])
      connect(tenant, :local, :listener, topic, "listener")
      tracker = connect(tenant, node_a, :tracker, topic, "tracker")
      ClusterPresence.track(tracker, topic, %{name: "alice"})
      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"joins" => %{"tracker" => _}}}}, @timeout

      Clustered.kill(node_a)

      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"leaves" => %{"tracker" => _}}}},
                     @timeout
    end
  end

  describe "a node that stops its application" do
    # The observer is a peer with a silence threshold that lasts much longer than the timeout of the
    # test, so only the goodbye of the stopping node can remove the entries in time.
    test "loses its entries on the other nodes before the silence threshold", %{tenant: tenant, topic: topic} do
      Clustered.configure_cluster([:rollcall_a, :rollcall_b])
      node_a = Clustered.start_peer(:rollcall_a)
      observer = Clustered.start_peer(:rollcall_b, rollcall: [silence_threshold: 1_000])
      Clustered.wait_for_muster([node(), node_a, observer])
      :ok = ClusterPresence.set_presence_mode(tenant, :rollcall, [node(), node_a, observer])
      connect(tenant, observer, :listener, topic, "listener")
      tracker = connect(tenant, node_a, :tracker, topic, "tracker")
      ClusterPresence.track(tracker, topic, %{name: "alice"})
      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"joins" => %{"tracker" => _}}}}, @timeout

      Clustered.stop_application(node_a)

      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"leaves" => %{"tracker" => _}}}},
                     @timeout
    end
  end

  defp connect(tenant, node, tag, topic, key) do
    {socket, _state} = ClusterPresence.connect_client(tenant, node, tag, topic: topic, key: key)
    socket
  end
end
