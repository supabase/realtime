defmodule Realtime.Integration.DistributedRealtimeChannelTest do
  # Use of Clustered
  use RealtimeWeb.ConnCase,
    async: false,
    parameterize: [%{serializer: Phoenix.Socket.V1.JSONSerializer}, %{serializer: RealtimeWeb.Socket.V2Serializer}]

  use Mimic

  alias Forum.Muster
  alias Phoenix.Socket.Message

  alias Realtime.FeatureFlags
  alias Realtime.Tenants.Connect
  alias Realtime.Integration.WebsocketClient

  # Evaluated on the peer too, so telemetry fired there can be forwarded to the test process.
  @aux_mod (quote do
              defmodule PeerTelemetry do
                def forward(event, measurements, metadata, %{pid: pid}) do
                  send(pid, {:peer_telemetry, event, measurements, metadata})
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
    setup :set_mimic_global

    setup %{node: node} do
      # Dave tracks on this node, so the flag only has to be on here; the peer just delivers.
      stub(FeatureFlags, :enabled?, fn
        "presence_latency_metric", _tenant -> true
        flag, tenant -> Mimic.call_original(FeatureFlags, :enabled?, [flag, tenant])
      end)

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

  # Actually as of today (2026-09-14) this doesn't yet go through Muster, as the flag
  # isn't yet turned on by default. As we want to roll out Muster further I'm still
  # keeping the gate here.
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
