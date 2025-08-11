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
    Endpoint.subscribe(@topic)

    :erpc.call(context.node, Subscriber, :subscribe, [self(), @topic])
    assert_receive :ready
    :ok
  end

  describe "broadcast/3" do
    test "broadcast", %{node: node} do
      payload = %{key: "value", from: self()}
      TenantBroadcaster.broadcast(@topic, "broadcast", payload)

      assert_receive %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}

      # Remote node received the broadcast
      assert_receive {:relay, ^node, %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}}
    end
  end

  describe "broadcast_from/4" do
    test "broadcast_from", %{node: node} do
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

      TenantBroadcaster.broadcast_from(self(), @topic, "broadcast", payload)

      assert_receive {:other_process, %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}}

      # Remote node received the broadcast
      assert_receive {:relay, ^node, %Broadcast{topic: @topic, event: "broadcast", payload: ^payload}}

      # This process does not receive the message
      refute_receive _any
    end
  end

  describe "pubsub_broadcast/3" do
    test "pubsub_broadcast", %{node: node} do
      TenantBroadcaster.pubsub_broadcast(@topic, "a message", Phoenix.PubSub)

      assert_receive "a message"

      # Remote node received the broadcast
      assert_receive {:relay, ^node, "a message"}
    end
  end

  describe "pubsub_broadcast_from/4" do
    test "pubsub_broadcast_from", %{node: node} do
      parent = self()

      spawn_link(fn ->
        Endpoint.subscribe(@topic)
        send(parent, :ready)

        receive do
          msg -> send(parent, {:other_process, msg})
        end
      end)

      assert_receive :ready

      TenantBroadcaster.pubsub_broadcast_from(self(), @topic, "a message", Phoenix.PubSub)

      assert_receive {:other_process, "a message"}

      # Remote node received the broadcast
      assert_receive {:relay, ^node, "a message"}

      # This process does not receive the message
      refute_receive _any
    end
  end
end
