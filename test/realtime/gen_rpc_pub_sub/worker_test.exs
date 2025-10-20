defmodule Realtime.GenRpcPubSub.WorkerTest do
  use ExUnit.Case, async: true
  alias Realtime.GenRpcPubSub.Worker
  alias Realtime.GenRpc
  alias Realtime.Nodes

  use Mimic

  @topic "test_topic"

  setup do
    worker = start_link_supervised!({Worker, {Realtime.PubSub, __MODULE__}})
    %{worker: worker}
  end

  describe "forward to local" do
    test "local broadcast", %{worker: worker} do
      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, @topic)
      send(worker, Worker.forward_to_local(@topic, "le message", Phoenix.PubSub))

      assert_receive "le message"
      refute_receive _any
    end
  end

  describe "forward to region" do
    setup %{worker: worker} do
      GenRpc
      |> stub()
      |> allow(self(), worker)

      Nodes
      |> stub()
      |> allow(self(), worker)

      :ok
    end

    test "local broadcast + forward to other nodes", %{worker: worker} do
      parent = self()
      expect(Nodes, :region_nodes, fn "us-east-1" -> [node(), :node_us_2, :node_us_3] end)

      expect(GenRpc, :abcast, fn [:node_us_2, :node_us_3],
                                 Realtime.GenRpcPubSub.WorkerTest,
                                 {:ftl, "test_topic", "le message", Phoenix.PubSub},
                                 [key: Realtime.GenRpcPubSub.WorkerTest] ->
        send(parent, :abcast_called)
        :ok
      end)

      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, @topic)
      send(worker, Worker.forward_to_region(@topic, "le message", Phoenix.PubSub))

      assert_receive "le message"
      assert_receive :abcast_called
      refute_receive _any
    end

    test "local broadcast and no other nodes", %{worker: worker} do
      expect(Nodes, :region_nodes, fn "us-east-1" -> [node()] end)

      reject(GenRpc, :abcast, 4)

      :ok = Phoenix.PubSub.subscribe(Realtime.PubSub, @topic)
      send(worker, Worker.forward_to_region(@topic, "le message", Phoenix.PubSub))

      assert_receive "le message"
      refute_receive _any
    end
  end
end
