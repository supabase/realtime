Application.put_env(:phoenix_pubsub, :test_adapter, {Realtime.GenRpcPubSub, []})
Code.require_file("../../deps/phoenix_pubsub/test/shared/pubsub_test.exs", __DIR__)

defmodule Realtime.GenRpcPubSubTest do
  # Application env being changed
  use ExUnit.Case, async: false

  test "it sets off_heap message_queue_data flag on the workers" do
    assert Realtime.PubSubElixir.Realtime.PubSub.Adapter_1
           |> Process.whereis()
           |> Process.info(:message_queue_data) == {:message_queue_data, :off_heap}
  end

  test "it sets fullsweep_after flag on the workers" do
    assert Realtime.PubSubElixir.Realtime.PubSub.Adapter_1
           |> Process.whereis()
           |> Process.info(:fullsweep_after) == {:fullsweep_after, 20}
  end

  @aux_mod (quote do
              defmodule Subscriber do
                # Relay messages to testing node
                def subscribe(subscriber, topic) do
                  spawn(fn ->
                    RealtimeWeb.Endpoint.subscribe(topic)
                    2 = length(Realtime.Nodes.region_nodes("us-east-1"))
                    2 = length(Realtime.Nodes.region_nodes("ap-southeast-2"))
                    send(subscriber, {:ready, Application.get_env(:realtime, :region)})

                    loop = fn f ->
                      receive do
                        msg -> send(subscriber, {:relay, node(), msg})
                      end

                      f.(f)
                    end

                    loop.(loop)
                  end)
                end

                # Register a long-lived local member for the tenant so this node reports hit=true.
                def add_user(tenant_id) do
                  pid = spawn(fn -> Process.sleep(:infinity) end)
                  :ok = Realtime.UsersCounter.add(pid, tenant_id)
                end

                # Relay the fan-out telemetry emitted on this (receiving) node back to the test process.
                def attach_fanout(dest) do
                  :telemetry.attach(
                    {__MODULE__, dest},
                    [:realtime, :broadcast, :fanout, :node_delivery],
                    &__MODULE__.relay_fanout/4,
                    dest
                  )
                end

                def relay_fanout(_event, measurements, metadata, dest) do
                  send(dest, {:fanout, node(), measurements, metadata})
                end
              end
            end)

  Code.eval_quoted(@aux_mod)

  @topic "gen-rpc-pub-sub-test-topic"

  describe "regional broadcasting" do
    setup do
      previous_region = Application.get_env(:realtime, :region)
      Application.put_env(:realtime, :region, "us-east-1")
      on_exit(fn -> Application.put_env(:realtime, :region, previous_region) end)

      :ok
    end

    test "broadcasts fan out across regions and each receiving node emits fan-out telemetry" do
      # start 1 node in us-east-1 to test my region broadcasting
      # start 2 nodes in ap-southeast-2 to test other region broadcasting

      us_node = :us_node
      ap2_nodeX = :ap2_nodeX
      ap2_nodeY = :ap2_nodeY

      # Avoid port collision
      gen_rpc_port = Application.fetch_env!(:gen_rpc, :tcp_server_port)

      client_config_per_node = %{
        node() => gen_rpc_port,
        :"#{us_node}@127.0.0.1" => 16970,
        :"#{ap2_nodeX}@127.0.0.1" => 16971,
        :"#{ap2_nodeY}@127.0.0.1" => 16972
      }

      extra_config = [{:gen_rpc, :client_config_per_node, {:internal, client_config_per_node}}]

      on_exit(fn -> Application.put_env(:gen_rpc, :client_config_per_node, {:internal, %{}}) end)
      Application.put_env(:gen_rpc, :client_config_per_node, {:internal, client_config_per_node})

      us_extra_config =
        [{:realtime, :region, "us-east-1"}, {:gen_rpc, :tcp_server_port, 16970}] ++ extra_config

      {:ok, _} = Clustered.start(@aux_mod, name: us_node, extra_config: us_extra_config, phoenix_port: 4014)

      ap2_nodeX_extra_config =
        [{:realtime, :region, "ap-southeast-2"}, {:gen_rpc, :tcp_server_port, 16971}] ++ extra_config

      {:ok, _} = Clustered.start(@aux_mod, name: ap2_nodeX, extra_config: ap2_nodeX_extra_config, phoenix_port: 4015)

      ap2_nodeY_extra_config =
        [{:realtime, :region, "ap-southeast-2"}, {:gen_rpc, :tcp_server_port, 16972}] ++ extra_config

      {:ok, _} = Clustered.start(@aux_mod, name: ap2_nodeY, extra_config: ap2_nodeY_extra_config, phoenix_port: 4016)

      # Ensuring that syn had enough time to propagate to all nodes the group information
      Process.sleep(3000)

      RealtimeWeb.Endpoint.subscribe(@topic)
      :erpc.multicall(Node.list(), Subscriber, :subscribe, [self(), @topic])

      assert length(Realtime.Nodes.region_nodes("us-east-1")) == 2
      assert length(Realtime.Nodes.region_nodes("ap-southeast-2")) == 2

      assert_receive {:ready, "us-east-1"}
      assert_receive {:ready, "ap-southeast-2"}
      assert_receive {:ready, "ap-southeast-2"}

      # Relay the fan-out telemetry emitted on every receiving node back to this process.
      for node <- Node.list(), do: :ok = :erpc.call(node, Subscriber, :attach_fanout, [self()])

      # Untagged broadcast: delivered to every node, but a no-op for fan-out telemetry.
      message = %Phoenix.Socket.Broadcast{topic: @topic, event: "an event", payload: ["a", %{"b" => "c"}, 1, 23]}
      Phoenix.PubSub.broadcast(Realtime.PubSub, @topic, message)

      assert_receive ^message

      # Remote nodes received the broadcast
      assert_receive {:relay, :"us_node@127.0.0.1", ^message}, 5000
      assert_receive {:relay, :"ap2_nodeX@127.0.0.1", ^message}, 1000
      assert_receive {:relay, :"ap2_nodeY@127.0.0.1", ^message}, 1000

      # Untagged messages do not emit fan-out telemetry
      refute_receive {:fanout, _, _, _}
      refute_receive _any

      # Tagged broadcast: fans out via :ftl (us_node, same region) and :ftr (ap nodes, other region),
      # and each receiving node emits the fan-out telemetry. Register a connection on us_node so it
      # reports hit=true while the ap nodes report hit=false.
      tenant_id = "fanout-#{System.unique_integer([:positive])}"
      :ok = :erpc.call(:"us_node@127.0.0.1", Subscriber, :add_user, [tenant_id])

      tagged_message = %Phoenix.Socket.Broadcast{topic: @topic, event: "an event", payload: %{"a" => "b"}}

      Phoenix.PubSub.broadcast(
        Realtime.PubSub,
        @topic,
        {:tb, tenant_id, tagged_message},
        RealtimeWeb.RealtimeChannel.MessageDispatcher
      )

      # The tag is stripped before delivery: subscribers only ever see the underlying struct
      assert_receive ^tagged_message
      assert_receive {:relay, :"us_node@127.0.0.1", ^tagged_message}, 5000
      assert_receive {:relay, :"ap2_nodeX@127.0.0.1", ^tagged_message}, 1000
      assert_receive {:relay, :"ap2_nodeY@127.0.0.1", ^tagged_message}, 1000

      # us_node holds a connection for the tenant (:ftl path) -> hit=true
      assert_receive {:fanout, :"us_node@127.0.0.1", %{local_tenant_users: us_count}, %{tenant: ^tenant_id, hit: true}},
                     5000

      assert us_count >= 1

      # ap nodes hold no connection for the tenant (:ftr path + its re-forwarded :ftl) -> hit=false
      assert_receive {:fanout, :"ap2_nodeX@127.0.0.1", %{local_tenant_users: 0}, %{tenant: ^tenant_id, hit: false}},
                     1000

      assert_receive {:fanout, :"ap2_nodeY@127.0.0.1", %{local_tenant_users: 0}, %{tenant: ^tenant_id, hit: false}},
                     1000

      refute_receive _any
    end
  end
end
