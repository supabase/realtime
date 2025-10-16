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
                    send(subscriber, :ready)

                    loop = fn f ->
                      receive do
                        msg -> send(subscriber, {:relay, node(), msg})
                      end

                      f.(f)
                    end

                    loop.(loop)
                  end)
                end
              end
            end)

  Code.eval_quoted(@aux_mod)

  @topic "gen-rpc-pub-sub-test-topic"

  for regional_broadcasting <- [true, false] do
    describe "regional balancing = #{regional_broadcasting}" do
      setup do
        value = Application.get_env(:realtime, :regional_broadcasting)
        Application.put_env(:realtime, :regional_broadcasting, unquote(regional_broadcasting))
        on_exit(fn -> Application.put_env(:realtime, :regional_broadcasting, value) end)

        :ok
      end

      @describetag regional_broadcasting: regional_broadcasting

      test "all messages are received" do
        # start 1 node in us-east-1 to test my region broadcasting
        # start 2 nodes in ap-southeast-2 to test other region broadcasting

        us_node = :us_node
        ap2_nodeX = :ap2_nodeX
        ap2_nodeY = :ap2_nodeY

        # Avoid port collision
        client_config_per_node = %{
          :"main@127.0.0.1" => 5369,
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

        RealtimeWeb.Endpoint.subscribe(@topic)
        :erpc.multicall(Node.list(), Subscriber, :subscribe, [self(), @topic])

        # Ensuring that syn had enough time to propagate to all nodes the group information
        Process.sleep(500)

        assert_receive :ready
        assert_receive :ready
        assert_receive :ready

        message = %Phoenix.Socket.Broadcast{topic: @topic, event: "an event", payload: ["a", %{"b" => "c"}, 1, 23]}
        Phoenix.PubSub.broadcast(Realtime.PubSub, @topic, message)

        assert_receive ^message

        # Remote nodes received the broadcast
        assert_receive {:relay, :"us_node@127.0.0.1", ^message}, 1000
        assert_receive {:relay, :"ap2_nodeX@127.0.0.1", ^message}, 1000
        assert_receive {:relay, :"ap2_nodeY@127.0.0.1", ^message}, 1000
        refute_receive _any
      end
    end
  end
end
