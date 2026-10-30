defmodule RealtimeWeb.RealtimeChannel.PresenceHandlerDistributedTest do
  # Usage of Clustered
  use Realtime.DataCase, async: false

  alias Phoenix.Socket.Broadcast
  alias Realtime.RateCounter
  alias Realtime.Tenants
  alias RealtimeWeb.RealtimeChannel.PresenceHandler

  setup do
    tenant = tenant_fixture()
    Tenants.Cache.update_cache(tenant)

    {:ok, peer, node} = Clustered.start_disconnected()
    true = Node.connect(node)

    %{tenant: tenant, peer: peer, node: node}
  end

  describe "sync/1" do
    @tag timeout: to_timeout(minute: 2)
    test "leaves out members that left when their node went down", %{tenant: tenant, peer: peer, node: node} do
      tenant_topic = Tenants.tenant_topic(tenant.external_id, random_string())
      RealtimeWeb.Endpoint.subscribe(tenant_topic)

      remote_pid = Node.spawn(node, Process, :sleep, [:infinity])
      {:ok, _} = :erpc.call(node, RealtimeWeb.Presence, :track, [remote_pid, tenant_topic, "remote", %{}])
      assert_receive %Broadcast{event: "presence_diff", payload: %{joins: %{"remote" => _}}}, 5_000

      assert ["remote"] = tenant |> synced_state(tenant_topic) |> Map.keys()

      :peer.stop(peer)

      # The tracker only reports the leave once the node has been silent for its down period
      assert_receive %Broadcast{event: "presence_diff", payload: %{leaves: %{"remote" => _}}}, 60_000

      assert synced_state(tenant, tenant_topic) == %{}
    end
  end

  defp synced_state(tenant, tenant_topic) do
    assert {:ok, _socket} = PresenceHandler.sync(socket_fixture(tenant, tenant_topic))
    assert_receive {:socket_push, :text, message}
    assert %{"event" => "presence_state", "payload" => state} = Jason.decode!(message)
    state
  end

  defp socket_fixture(tenant, tenant_topic) do
    rate = Tenants.presence_events_per_second_rate(tenant)
    RateCounter.new(rate)

    %Phoenix.Socket{
      joined: true,
      topic: "realtime:#{random_string()}",
      transport_pid: self(),
      serializer: Phoenix.Socket.V1.JSONSerializer,
      assigns: %{
        tenant_topic: tenant_topic,
        presence_rate_counter: rate,
        private?: false,
        presence_enabled?: true,
        log_level: :error,
        tenant: tenant.external_id
      }
    }
  end
end
