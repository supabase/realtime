defmodule Realtime.Integration.PresenceDistributedTest do
  # Starts peer nodes with Clustered, so the tests cannot run at the same time as other tests.
  #
  # The tests run in the Rollcall mode, with clients on different nodes of a real cluster. They
  # assert what a client receives. The Phoenix mode is covered by the presence tests of one node.
  # The peers start once for the module, and each test uses a tenant of its own.
  use RealtimeWeb.ConnCase, async: false

  alias Phoenix.Socket.Message
  alias Realtime.Integration.WebsocketClient

  @moduletag :capture_log
  # A remote change arrives with the next heartbeat.
  @remote_timeout 5_000

  setup_all do
    %{nodes: Clustered.start_peers([:rollcall_a, :rollcall_b])}
  end

  setup %{nodes: nodes} do
    tenant = TestTenantDb.checkout_tenant_unboxed(run_migrations: true)
    :ok = ClusterPresence.set_presence_mode(tenant, :rollcall, [node() | nodes])

    %{tenant: tenant, topic: "realtime:#{random_string()}"}
  end

  describe "a track on one node" do
    # The listener never tracks. This is the case of a node with subscribers and no local track.
    test "reaches a client that never tracks on another node, and a client that joins later", ctx do
      %{tenant: tenant, topic: topic, nodes: [node_a, _node_b]} = ctx
      connect(tenant, node_a, :listener, topic, "listener")
      tracker = connect(tenant, :local, :tracker, topic, "tracker")

      ClusterPresence.track(tracker, topic, %{name: "alice"})

      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"joins" => %{"tracker" => _}}}},
                     @remote_timeout

      {_socket, state} = ClusterPresence.connect_client(tenant, node_a, :late, topic: topic, key: "late")
      assert %{"tracker" => %{"metas" => [%{"name" => "alice"}]}} = state
    end

    test "that replaces the entry reaches another node as one diff with a leave and a join", ctx do
      %{tenant: tenant, topic: topic, nodes: [node_a, _node_b]} = ctx
      connect(tenant, node_a, :listener, topic, "listener")
      tracker = connect(tenant, :local, :tracker, topic, "tracker")
      ClusterPresence.track(tracker, topic, %{name: "first"})

      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"joins" => %{"tracker" => _}}}},
                     @remote_timeout

      ClusterPresence.track(tracker, topic, %{name: "second"})

      assert_receive {:listener,
                      %Message{
                        event: "presence_diff",
                        payload: %{
                          "joins" => %{"tracker" => %{"metas" => [%{"name" => "second"}]}},
                          "leaves" => %{"tracker" => %{"metas" => [%{"name" => "first"}]}}
                        }
                      }},
                     @remote_timeout
    end
  end

  describe "the end of an entry on one node" do
    test "reaches another node as a leave when the client untracks", ctx do
      %{tenant: tenant, topic: topic, nodes: [node_a, _node_b]} = ctx
      connect(tenant, node_a, :listener, topic, "listener")
      tracker = connect(tenant, :local, :tracker, topic, "tracker")
      ClusterPresence.track(tracker, topic, %{name: "alice"})

      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"joins" => %{"tracker" => _}}}},
                     @remote_timeout

      ClusterPresence.untrack(tracker, topic)

      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"leaves" => %{"tracker" => _}}}},
                     @remote_timeout
    end

    test "reaches another node as a leave when the client closes the socket", ctx do
      %{tenant: tenant, topic: topic, nodes: [node_a, _node_b]} = ctx
      connect(tenant, node_a, :listener, topic, "listener")
      tracker = connect(tenant, :local, :tracker, topic, "tracker")
      ClusterPresence.track(tracker, topic, %{name: "alice"})

      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"joins" => %{"tracker" => _}}}},
                     @remote_timeout

      WebsocketClient.close(tracker)

      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"leaves" => %{"tracker" => _}}}},
                     @remote_timeout
    end
  end

  describe "a client that tracked and untracked" do
    # The Rollcall tracker of a node with no entry stops after the grace period, unless a client on
    # the node still listens. The test waits for two grace periods, then expects the listener to
    # receive. No condition shows a tracker that does not stop, so the test waits for the time.
    test "keeps receiving after the grace period of the tracker ends", ctx do
      %{tenant: tenant, topic: topic, nodes: [node_a, _node_b]} = ctx
      listener = connect(tenant, node_a, :listener, topic, "listener")
      ClusterPresence.track(listener, topic, %{name: "listener"})
      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"joins" => %{"listener" => _}}}}, 2_000
      ClusterPresence.untrack(listener, topic)
      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"leaves" => %{"listener" => _}}}}, 2_000
      Process.sleep(2 * grace_period_in_ms())

      tracker = connect(tenant, :local, :tracker, topic, "tracker")
      ClusterPresence.track(tracker, topic, %{name: "alice"})

      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"joins" => %{"tracker" => _}}}},
                     @remote_timeout
    end
  end

  describe "a track in the shadow mode" do
    # Rollcall tracks and replicates the entries between the nodes, and Phoenix serves the clients.
    # Rollcall publishes to no client, so a client receives the diff once.
    test "reaches a client on another node once, and a client that joins later", ctx do
      %{tenant: tenant, topic: topic, nodes: [node_a, _node_b] = nodes} = ctx
      :ok = ClusterPresence.set_presence_mode(tenant, :shadow, [node() | nodes])
      connect(tenant, node_a, :listener, topic, "listener")
      tracker = connect(tenant, :local, :tracker, topic, "tracker")

      ClusterPresence.track(tracker, topic, %{name: "alice"})

      assert_receive {:listener, %Message{event: "presence_diff", payload: %{"joins" => %{"tracker" => _}}}},
                     @remote_timeout

      refute_receive {:listener, %Message{event: "presence_diff"}}, 300

      {_socket, state} = ClusterPresence.connect_client(tenant, node_a, :late, topic: topic, key: "late")
      assert %{"tracker" => %{"metas" => [%{"name" => "alice"}]}} = state
    end
  end

  describe "clients on three nodes" do
    test "see each other", ctx do
      %{tenant: tenant, topic: topic, nodes: [node_a, node_b]} = ctx
      clients = [local: :local, a: node_a, b: node_b]

      sockets =
        for {tag, node} <- clients do
          socket = connect(tenant, node, tag, topic, "key-#{tag}")
          {tag, socket}
        end

      for {tag, socket} <- sockets, do: ClusterPresence.track(socket, topic, %{name: "name-#{tag}"})

      # Each client receives the join of each of the other two.
      for {tag, _node} <- clients, other <- Keyword.keys(clients) -- [tag] do
        key = "key-#{other}"

        assert_receive {^tag, %Message{event: "presence_diff", payload: %{"joins" => %{^key => _}}}}, @remote_timeout
      end
    end
  end

  defp connect(tenant, node, tag, topic, key) do
    {socket, _state} = ClusterPresence.connect_client(tenant, node, tag, topic: topic, key: key)
    socket
  end

  defp grace_period_in_ms do
    :realtime |> Application.fetch_env!(:rollcall) |> Keyword.fetch!(:empty_grace_in_ms)
  end
end
