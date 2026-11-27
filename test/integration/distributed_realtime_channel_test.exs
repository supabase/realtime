defmodule Realtime.Integration.DistributedRealtimeChannelTest do
  # Use of Clustered
  use RealtimeWeb.ConnCase,
    async: false,
    parameterize: [%{serializer: Phoenix.Socket.V1.JSONSerializer}, %{serializer: RealtimeWeb.Socket.V2Serializer}]

  alias Forum.Muster
  alias Phoenix.Socket.Message

  alias Realtime.Tenants.Connect
  alias Realtime.Integration.WebsocketClient
  alias RealtimeWeb.BroadcastDeliveryMetrics
  alias RealtimeWeb.UserSocket

  @service_restart_close_code 1012

  # Evaluated on the peer too, so telemetry fired there can be forwarded to the test process.
  @aux_mod (quote do
              defmodule PeerTelemetry do
                def forward(event, measurements, metadata, %{pid: pid}) do
                  send(pid, {:peer_telemetry, event, measurements, metadata})
                end

                def forward_delivery(_event, measurements, metadata, %{pid: pid}) do
                  send(pid, {:delivery, node(), measurements, metadata})
                end
              end
            end)

  Code.eval_quoted(@aux_mod)

  setup do
    tenant = TestTenantDb.checkout_tenant_unboxed(run_migrations: true)

    {:ok, node} = Clustered.start(@aux_mod)
    region = Realtime.Tenants.region(tenant)
    {:ok, db_conn} = :erpc.call(node, Connect, :connect, [tenant.external_id, region])
    assert Connect.ready?(tenant.external_id)

    assert node(db_conn) == node

    wait_for_muster_ready(node, region)

    %{tenant: tenant, topic: random_string(), node: node}
  end

  describe "distributed presence latency" do
    setup %{node: node} do
      # Dave tracks on this node, so the rate only has to be set here; the peer just delivers.
      set_presence_sample_rate(1.0)

      latency = [:realtime, :presence, :notify, :latency]
      :ok = :telemetry.attach({__MODULE__, :local}, latency, &PeerTelemetry.forward/4, %{pid: self()})

      :ok =
        :erpc.call(node, :telemetry, :attach, [{__MODULE__, :peer}, latency, &PeerTelemetry.forward/4, %{pid: self()}])

      on_exit(fn -> :telemetry.detach({__MODULE__, :local}) end)
      :ok
    end

    @tag mode: :distributed
    test "a member on another node is measured as a remote notification", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer
    } do
      tenant_id = tenant.external_id

      {:ok, token} =
        generate_token(tenant, %{exp: System.system_time(:second) + 1000, role: "authenticated", sub: random_string()})

      {:ok, remote_socket} =
        WebsocketClient.connect(self(), uri(tenant, serializer, TestEnv.peer_http_port()), serializer, [
          {"x-api-key", token}
        ])

      {:ok, socket} = WebsocketClient.connect(self(), uri(tenant, serializer), serializer, [{"x-api-key", token}])

      config = %{presence: %{key: "", enabled: true}, private: false}
      topic = "realtime:#{topic}"

      :ok = WebsocketClient.join(remote_socket, topic, %{config: config})
      :ok = WebsocketClient.join(socket, topic, %{config: config})

      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 5000
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 5000
      assert_receive %Message{event: "presence_state", topic: ^topic}, 5000
      assert_receive %Message{event: "presence_state", topic: ^topic}, 5000

      :ok =
        WebsocketClient.send_event(socket, topic, "presence", %{
          type: "presence",
          event: "TRACK",
          payload: %{name: "dave"}
        })

      # Both members receive the diff: Dave's own at once, the remote member's after the next
      # Tracker heartbeat. Neither carries the envelope.
      for _ <- 1..2 do
        assert_receive %Message{event: "presence_diff", payload: %{"joins" => joins}, topic: ^topic}, 5000
        assert [meta] = joins |> Map.values() |> hd() |> Map.fetch!("metas")
        refute Map.has_key?(meta, "_rt")
      end

      assert_receive {:peer_telemetry, _, %{latency: local_latency},
                      %{tenant: ^tenant_id, origin: :local, path: :fastlane, action: :track}},
                     5000

      assert_receive {:peer_telemetry, _, %{latency: remote_latency},
                      %{tenant: ^tenant_id, origin: :remote, path: :fastlane, action: :track}},
                     5000

      assert local_latency >= 0
      # Remote delivery waits for the Tracker heartbeat, so it cannot be instant.
      assert remote_latency >= local_latency
      refute_receive {:peer_telemetry, _, _, _}
    end
  end

  describe "distributed broadcast" do
    @tag mode: :distributed
    test "it works", %{tenant: tenant, topic: topic, serializer: serializer} do
      {:ok, token} =
        generate_token(tenant, %{exp: System.system_time(:second) + 1000, role: "authenticated", sub: random_string()})

      {:ok, remote_socket} =
        WebsocketClient.connect(self(), uri(tenant, serializer, TestEnv.peer_http_port()), serializer, [
          {"x-api-key", token}
        ])

      {:ok, socket} = WebsocketClient.connect(self(), uri(tenant, serializer), serializer, [{"x-api-key", token}])

      config = %{broadcast: %{self: false}, private: false}
      topic = "realtime:#{topic}"

      :ok = WebsocketClient.join(remote_socket, topic, %{config: config})
      :ok = WebsocketClient.join(socket, topic, %{config: config})

      # Wait for both channels to have successfully joined, as a broadcast is fire
      # and forget.
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 5000
      assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 5000

      # Send through one socket and receive through the other (self: false)
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      :ok = WebsocketClient.send_event(remote_socket, topic, "broadcast", payload)

      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 5000
    end
  end

  describe "distributed broadcast delivery latency" do
    setup %{tenant: tenant, topic: topic, serializer: serializer, node: node} do
      for n <- [node(), node] do
        args = [
          {__MODULE__, :delivery},
          BroadcastDeliveryMetrics.event(),
          &PeerTelemetry.forward_delivery/4,
          %{pid: self()}
        ]

        :ok = :erpc.call(n, :telemetry, :attach, args)
      end

      on_exit(fn -> :telemetry.detach({__MODULE__, :delivery}) end)

      {:ok, token} =
        generate_token(tenant, %{exp: System.system_time(:second) + 1000, role: "authenticated", sub: random_string()})

      topic = "realtime:#{topic}"
      local_socket = connect_and_join(tenant, serializer, nil, token, topic, self: false)
      connect_and_join(tenant, serializer, TestEnv.peer_http_port(), token, topic, self: false)

      %{topic: topic, local_socket: local_socket}
    end

    @tag mode: :distributed
    test "a client broadcast is measured only on the node of the client that receives it", %{
      tenant: tenant,
      topic: topic,
      node: node,
      local_socket: local_socket
    } do
      tenant_id = tenant.external_id
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}

      :ok = WebsocketClient.send_event(local_socket, topic, "broadcast", payload)

      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 5000

      assert_receive {:delivery, ^node, %{latency: latency}, %{tenant: ^tenant_id, origin: :remote}}
                     when is_integer(latency),
                     5000

      refute_receive {:delivery, _, _, %{tenant: ^tenant_id}}
    end

    @tag mode: :distributed
    test "an API broadcast is measured once on each node with a subscriber", %{tenant: tenant, topic: topic, node: node} do
      tenant_id = tenant.external_id
      local_node = node()
      now = System.system_time(:second)
      token = generate_jwt_token(tenant, %{role: "test", iat: now, exp: now + 100})
      "realtime:" <> subtopic = topic

      conn =
        build_conn()
        |> put_req_header("authorization", "Bearer #{token}")
        |> then(&%{&1 | host: "#{tenant_id}.supabase.com"})
        |> post(~p"/api/broadcast", %{"messages" => [%{"topic" => subtopic, "event" => "e", "payload" => %{}}]})

      assert conn.status == 202
      assert_receive %Message{event: "broadcast", topic: ^topic}, 5000
      assert_receive %Message{event: "broadcast", topic: ^topic}, 5000
      assert_receive {:delivery, ^local_node, _, %{tenant: ^tenant_id, origin: :local}}, 5000
      assert_receive {:delivery, ^node, _, %{tenant: ^tenant_id, origin: :remote}}, 5000
      refute_receive {:delivery, _, _, %{tenant: ^tenant_id}}
    end
  end

  describe "tenant suspension" do
    @tag mode: :distributed
    test "closes the sockets on every node", %{tenant: tenant, topic: topic, serializer: serializer} do
      {:ok, token} = generate_token(tenant, %{exp: System.system_time(:second) + 1000, role: "authenticated"})
      topic = "realtime:#{topic}"

      remote_socket = connect_and_join(tenant, serializer, TestEnv.peer_http_port(), token, topic)
      socket = connect_and_join(tenant, serializer, nil, token, topic)

      suspend(tenant)

      assert_receive {:close_code, @service_restart_close_code}, 5000
      assert_receive {:close_code, @service_restart_close_code}, 5000
      assert_process_down(remote_socket)
      assert_process_down(socket)
    end

    @tag mode: :distributed
    test "kills a socket on another node that does not drain", %{
      tenant: tenant,
      topic: topic,
      serializer: serializer,
      node: node
    } do
      {:ok, token} = generate_token(tenant, %{exp: System.system_time(:second) + 1000, role: "authenticated"})
      remote_socket = connect_and_join(tenant, serializer, TestEnv.peer_http_port(), token, "realtime:#{topic}")

      # A suspended transport never handles the drain, like one that is stuck or missed the broadcast
      id = UserSocket.subscribers_id(tenant.external_id)
      [{transport_pid, _}] = :erpc.call(node, Registry, :lookup, [Realtime.PubSub, id])
      :ok = :erpc.call(node, :sys, :suspend, [transport_pid])
      ref = Process.monitor(transport_pid)

      suspend(tenant)

      assert_receive {:DOWN, ^ref, :process, ^transport_pid, :killed}, 5000
      assert_process_down(remote_socket)
      refute_received {:close_code, _}
    end
  end

  # nil makes uri/3 use this node's port
  defp connect_and_join(tenant, serializer, port, token, topic, opts \\ []) do
    opts = Keyword.validate!(opts, self: true)
    {:ok, socket} = WebsocketClient.connect(self(), uri(tenant, serializer, port), serializer, [{"x-api-key", token}])
    :ok = WebsocketClient.join(socket, topic, %{config: %{broadcast: %{self: opts[:self]}, private: false}})
    assert_receive %Message{event: "phx_reply", payload: %{"status" => "ok"}, topic: ^topic}, 5000
    socket
  end

  # The tenant row lives outside the sandbox, so the update has to as well
  defp suspend(tenant) do
    {:ok, _} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Realtime.Repo, fn ->
        Realtime.Api.update_tenant_by_external_id(tenant.external_id, %{suspend: true})
      end)
  end

  # Broadcasts route through Muster's region ring, so wait for the local and
  # peer node to both consider it :ready and agree on the same ring view before
  # sending anything cross-node.
  defp wait_for_muster_ready(node, region) do
    scope = :"realtime_channels_#{region}"

    assert_eventually(
      Muster.status(scope) == :ready and
        :erpc.call(node, Muster, :status, [scope]) == :ready and
        Muster.view_hash(scope) == :erpc.call(node, Muster, :view_hash, [scope]),
      timeout: to_timeout(second: 15)
    )
  end
end
