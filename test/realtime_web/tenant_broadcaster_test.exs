defmodule RealtimeWeb.TenantBroadcasterTest do
  # Usage of Clustered and changing Application env
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

    on_exit(fn -> :telemetry.detach(__MODULE__) end)

    :telemetry.attach(
      __MODULE__,
      [:realtime, :tenants, :payload, :size],
      &__MODULE__.handle_telemetry/4,
      pid: self()
    )

    original = Application.fetch_env!(:realtime, :pubsub_adapter)
    on_exit(fn -> Application.put_env(:realtime, :pubsub_adapter, original) end)
    Application.put_env(:realtime, :pubsub_adapter, context.pubsub_adapter)

    :ok
  end

  for pubsub_adapter <- [:gen_rpc, :pg2] do
    describe "pubsub_broadcast/4 #{pubsub_adapter}" do
      @describetag pubsub_adapter: pubsub_adapter

      test "pubsub_broadcast", %{node: node} do
        message = %Broadcast{topic: @topic, event: "an event", payload: %{"a" => "b"}}
        TenantBroadcaster.pubsub_broadcast("realtime-dev", @topic, message, Phoenix.PubSub, :broadcast)

        assert_receive ^message

        # Remote node received the broadcast
        assert_receive {:relay, ^node, ^message}

        assert_receive {
          :telemetry,
          [:realtime, :tenants, :payload, :size],
          %{size: 114},
          %{tenant: "realtime-dev", message_type: :broadcast}
        }
      end

      test "pubsub_broadcast list payload", %{node: node} do
        message = %Broadcast{topic: @topic, event: "an event", payload: ["a", %{"b" => "c"}, 1, 23]}
        TenantBroadcaster.pubsub_broadcast("realtime-dev", @topic, message, Phoenix.PubSub, :broadcast)

        assert_receive ^message

        # Remote node received the broadcast
        assert_receive {:relay, ^node, ^message}

        assert_receive {
          :telemetry,
          [:realtime, :tenants, :payload, :size],
          %{size: 130},
          %{tenant: "realtime-dev", message_type: :broadcast}
        }
      end

      test "pubsub_broadcast string payload", %{node: node} do
        message = %Broadcast{topic: @topic, event: "an event", payload: "some text payload"}
        TenantBroadcaster.pubsub_broadcast("realtime-dev", @topic, message, Phoenix.PubSub, :broadcast)

        assert_receive ^message

        # Remote node received the broadcast
        assert_receive {:relay, ^node, ^message}

        assert_receive {
          :telemetry,
          [:realtime, :tenants, :payload, :size],
          %{size: 119},
          %{tenant: "realtime-dev", message_type: :broadcast}
        }
      end
    end
  end

  for pubsub_adapter <- [:gen_rpc, :pg2] do
    describe "pubsub_broadcast_from/5 #{pubsub_adapter}" do
      @describetag pubsub_adapter: pubsub_adapter

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

        message = %Broadcast{topic: @topic, event: "an event", payload: %{"a" => "b"}}

        TenantBroadcaster.pubsub_broadcast_from("realtime-dev", self(), @topic, message, Phoenix.PubSub, :broadcast)

        assert_receive {:other_process, ^message}

        # Remote node received the broadcast
        assert_receive {:relay, ^node, ^message}

        assert_receive {
          :telemetry,
          [:realtime, :tenants, :payload, :size],
          %{size: 114},
          %{tenant: "realtime-dev", message_type: :broadcast}
        }

        # This process does not receive the message
        refute_receive _any
      end
    end
  end

  describe "collect_payload_size/3" do
    @describetag pubsub_adapter: :gen_rpc

    test "emit telemetry for struct" do
      TenantBroadcaster.collect_payload_size(
        "realtime-dev",
        %Phoenix.Socket.Broadcast{event: "broadcast", payload: %{"a" => "b"}},
        :broadcast
      )

      assert_receive {:telemetry, [:realtime, :tenants, :payload, :size], %{size: 65},
                      %{tenant: "realtime-dev", message_type: :broadcast}}
    end

    test "emit telemetry for map" do
      TenantBroadcaster.collect_payload_size(
        "realtime-dev",
        %{event: "broadcast", payload: %{"a" => "b"}},
        :postgres_changes
      )

      assert_receive {:telemetry, [:realtime, :tenants, :payload, :size], %{size: 53},
                      %{tenant: "realtime-dev", message_type: :postgres_changes}}
    end

    test "emit telemetry for non-map" do
      TenantBroadcaster.collect_payload_size("realtime-dev", "some blob", :presence)

      assert_receive {:telemetry, [:realtime, :tenants, :payload, :size], %{size: 15},
                      %{tenant: "realtime-dev", message_type: :presence}}
    end
  end

  def handle_telemetry(event, measures, metadata, pid: pid), do: send(pid, {:telemetry, event, measures, metadata})
end
