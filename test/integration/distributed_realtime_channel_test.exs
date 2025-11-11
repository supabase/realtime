defmodule Realtime.Integration.DistributedRealtimeChannelTest do
  # Use of Clustered
  use RealtimeWeb.ConnCase,
    async: false,
    parameterize: [%{serializer: Phoenix.Socket.V1.JSONSerializer}, %{serializer: RealtimeWeb.Socket.V2Serializer}]

  alias Phoenix.Socket.Message

  alias Realtime.Tenants.Connect
  alias Realtime.Integration.WebsocketClient

  setup do
    tenant = Realtime.Api.get_tenant_by_external_id("dev_tenant")

    RateCounterHelper.stop(tenant.external_id)

    Connect.shutdown(tenant.external_id)
    # Sleeping so that syn can forget about this Connect process
    Process.sleep(100)

    on_exit(fn ->
      Connect.shutdown(tenant.external_id)
      # Sleeping so that syn can forget about this Connect process
      Process.sleep(100)
    end)

    on_exit(fn -> Connect.shutdown(tenant.external_id) end)
    {:ok, node} = Clustered.start()
    region = Realtime.Tenants.region(tenant)
    {:ok, db_conn} = :erpc.call(node, Connect, :connect, ["dev_tenant", region])
    assert Connect.ready?(tenant.external_id)

    assert node(db_conn) == node
    %{tenant: tenant, topic: random_string()}
  end

  describe "distributed broadcast" do
    @tag mode: :distributed
    test "it works", %{tenant: tenant, topic: topic, serializer: serializer} do
      {:ok, token} =
        generate_token(tenant, %{exp: System.system_time(:second) + 1000, role: "authenticated", sub: random_string()})

      {:ok, remote_socket} =
        WebsocketClient.connect(self(), uri(tenant, serializer, 4012), serializer, [{"x-api-key", token}])

      {:ok, socket} = WebsocketClient.connect(self(), uri(tenant, serializer), serializer, [{"x-api-key", token}])

      config = %{broadcast: %{self: false}, private: false}
      topic = "realtime:#{topic}"

      :ok = WebsocketClient.join(remote_socket, topic, %{config: config})
      :ok = WebsocketClient.join(socket, topic, %{config: config})

      # Send through one socket and receive through the other (self: false)
      payload = %{"event" => "TEST", "payload" => %{"msg" => 1}, "type" => "broadcast"}
      :ok = WebsocketClient.send_event(remote_socket, topic, "broadcast", payload)

      assert_receive %Message{event: "broadcast", payload: ^payload, topic: ^topic}, 2000
    end
  end
end
