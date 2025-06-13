defmodule RealtimeWeb.TenantBroadcasterTest do
  use Realtime.DataCase, async: true

  alias Phoenix.Socket.Broadcast
  alias RealtimeWeb.Endpoint
  alias RealtimeWeb.TenantBroadcaster

  @payload %{a: "b", c: "e"}
  @topic "test-topic"

  setup context do
    tenant = tenant_fixture(broadcast_adapter: context[:adapter])
    Endpoint.subscribe(@topic)
    %{tenant: tenant}
  end

  describe "phoenix adapter" do
    @describetag adapter: :phoenix

    test "broadcast", %{tenant: tenant} do
      TenantBroadcaster.broadcast(tenant, @topic, "broadcast", @payload)

      assert_receive %Broadcast{topic: @topic, event: "broadcast", payload: @payload}
    end

    test "broadcast_from", %{tenant: tenant} do
      parent = self()

      spawn_link(fn ->
        Endpoint.subscribe(@topic)
        send(parent, :ready)

        receive do
          msg -> send(parent, {:other_process, msg})
        end
      end)

      assert_receive :ready

      TenantBroadcaster.broadcast_from(tenant, self(), @topic, "broadcast", @payload)

      refute_receive %Broadcast{topic: @topic, event: "broadcast", payload: @payload}
      assert_receive {:other_process, %Broadcast{topic: @topic, event: "broadcast", payload: @payload}}
    end
  end

  describe "gen_rpc adapter" do
    @describetag adapter: :gen_rpc

    test "broadcast", %{tenant: tenant} do
      TenantBroadcaster.broadcast(tenant, @topic, "broadcast", @payload)

      assert_receive %Broadcast{topic: @topic, event: "broadcast", payload: @payload}
    end

    test "broadcast_from", %{tenant: tenant} do
      parent = self()

      spawn_link(fn ->
        Endpoint.subscribe(@topic)
        send(parent, :ready)

        receive do
          msg -> send(parent, {:other_process, msg})
        end
      end)

      assert_receive :ready

      TenantBroadcaster.broadcast_from(tenant, self(), @topic, "broadcast", @payload)

      refute_receive %Broadcast{topic: @topic, event: "broadcast", payload: @payload}
      assert_receive {:other_process, %Broadcast{topic: @topic, event: "broadcast", payload: @payload}}
    end
  end
end
