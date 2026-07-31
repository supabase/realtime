defmodule Realtime.GenRpcPubSub.WorkerTest do
  use ExUnit.Case, async: true
  alias Realtime.GenRpcPubSub.Worker
  alias Realtime.GenRpc
  alias Realtime.Nodes

  use Mimic

  setup :set_mimic_from_context

  @topic "test_topic"
  @fanout_event [:realtime, :broadcast, :fanout, :node_delivery]

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
                                 [] ->
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

  describe "broadcast fan-out telemetry" do
    setup do
      ref = :telemetry_test.attach_event_handlers(self(), [@fanout_event])
      tenant_id = "worker-#{System.unique_integer([:positive])}"
      %{ref: ref, tenant_id: tenant_id}
    end

    test "forward to local emits hit=true when the node holds a connection for the tenant",
         %{worker: worker, ref: ref, tenant_id: tenant_id} do
      :ok = Realtime.UsersCounter.add(self(), tenant_id)

      message = {:tb, tenant_id, %Phoenix.Socket.Broadcast{topic: @topic, event: "e", payload: %{}}}
      send(worker, Worker.forward_to_local(@topic, message, Phoenix.PubSub))

      assert_receive {@fanout_event, ^ref, %{local_tenant_users: count}, %{tenant: ^tenant_id, hit: true}}, 500
      assert count >= 1
      refute_receive {@fanout_event, ^ref, _, %{tenant: ^tenant_id}}
    end

    test "forward to local emits hit=false when the node holds no connection for the tenant",
         %{worker: worker, ref: ref, tenant_id: tenant_id} do
      message = {:tb, tenant_id, %Phoenix.Socket.Broadcast{topic: @topic, event: "e", payload: %{}}}
      send(worker, Worker.forward_to_local(@topic, message, Phoenix.PubSub))

      assert_receive {@fanout_event, ^ref, %{local_tenant_users: 0}, %{tenant: ^tenant_id, hit: false}}, 500
      refute_receive {@fanout_event, ^ref, _, %{tenant: ^tenant_id}}
    end

    test "does not emit for untagged messages", %{worker: worker, ref: ref, tenant_id: tenant_id} do
      send(worker, Worker.forward_to_local(@topic, "untagged message", Phoenix.PubSub))

      refute_receive {@fanout_event, ^ref, _, %{tenant: ^tenant_id}}
    end

    test "forward to region also measures fan-out on the receiving node",
         %{worker: worker, ref: ref, tenant_id: tenant_id} do
      GenRpc
      |> stub()
      |> allow(self(), worker)

      Nodes
      |> stub()
      |> allow(self(), worker)

      expect(Nodes, :region_nodes, fn "us-east-1" -> [node()] end)

      message = {:tb, tenant_id, %Phoenix.Socket.Broadcast{topic: @topic, event: "e", payload: %{}}}
      send(worker, Worker.forward_to_region(@topic, message, Phoenix.PubSub))

      assert_receive {@fanout_event, ^ref, %{local_tenant_users: 0}, %{tenant: ^tenant_id, hit: false}}, 500
      refute_receive {@fanout_event, ^ref, _, %{tenant: ^tenant_id}}
    end
  end
end
