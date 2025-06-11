defmodule RealtimeWeb.TenantBroadcasterTest do
  # Usage of Clustered
  use Realtime.DataCase, async: false

  alias Phoenix.Socket.Broadcast
  alias RealtimeWeb.Endpoint
  alias RealtimeWeb.TenantBroadcaster

  @topic "test-topic" <> to_string(__MODULE__)

  @aux_mod (quote do
              defmodule Subscriber do
                # Relay messages to testing node
                def subscribe(subscriber, topic) do
                  spawn(fn ->
                    RealtimeWeb.Endpoint.subscribe(topic)
                    send(subscriber, :ready)

                    receive do
                      msg ->
                        send(subscriber, {:relay, node(), msg})
                    end
                  end)
                end
              end
            end)

  setup_all do
    {:ok, node} = Clustered.start(@aux_mod)

    %{node: node}
  end

  setup context do
    tenant = tenant_fixture(broadcast_adapter: context[:adapter])
    Endpoint.subscribe(@topic)

    :erpc.call(context.node, Subscriber, :subscribe, [self(), @topic])
    assert_receive :ready
    %{tenant: tenant}
  end

  describe "phoenix adapter" do
    @describetag adapter: :phoenix

    test "broadcast", %{tenant: tenant, node: node} do
      payload = %{key: "value", from: self()}
      TenantBroadcaster.broadcast(tenant, @topic, "broadcast", payload)

      assert_receive %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}

      # Remote node receive the broadcast
      assert_receive {:relay, ^node, %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}}
    end

    test "broadcast_from", %{tenant: tenant, node: node} do
      payload = %{key: "value", from: self()}
      parent = self()

      spawn_link(fn ->
        Endpoint.subscribe(@topic)
        send(parent, :ready)

        receive do
          msg -> send(parent, {:other_process, msg})
        end
      end)

      assert_receive :ready

      TenantBroadcaster.broadcast_from(tenant, self(), @topic, "broadcast", payload)

      assert_receive {:other_process, %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}}

      # Remote node receive the broadcast
      assert_receive {:relay, ^node, %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}}

      # This process does not receive the message
      refute_receive _any
    end
  end

  describe "gen_rpc adapter" do
    @describetag adapter: :gen_rpc

    test "broadcast", %{tenant: tenant, node: node} do
      payload = %{key: "value", from: self()}
      TenantBroadcaster.broadcast(tenant, @topic, "broadcast", payload)

      assert_receive %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}

      # Remote node receive the broadcast
      assert_receive {:relay, ^node, %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}}
    end

    test "broadcast_from", %{tenant: tenant, node: node} do
      payload = %{key: "value", from: self()}
      parent = self()

      spawn_link(fn ->
        Endpoint.subscribe(@topic)
        send(parent, :ready)

        receive do
          msg -> send(parent, {:other_process, msg})
        end
      end)

      assert_receive :ready

      TenantBroadcaster.broadcast_from(tenant, self(), @topic, "broadcast", payload)

      assert_receive {:other_process, %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}}

      # Remote node receive the broadcast
      assert_receive {:relay, ^node, %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}}

      # This process does not receive the message
      refute_receive _any
    end
  end
end
