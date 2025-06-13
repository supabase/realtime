defmodule Realtime.Monitoring.LatencyTest do
  # async: false due to the usage of Clustered mode that interacts with this tests and breaks their expectations
  use Realtime.DataCase, async: false
  alias Realtime.Latency
  alias Realtime.Latency.Payload

  describe "ping/3" do
    setup do
      {:ok, node} = Clustered.start()
      :ok = :erpc.call(node, Application, :put_env, [:realtime, :region, "ap-southeast-2"])

      :ok = RealtimeWeb.Endpoint.subscribe("admin:cluster")

      %{node: node}
    end

    test "locally with a healthy remote node" do
      assert [
               {%Task{},
                {:ok,
                 %Payload{
                   from_node: "127.0.0.1",
                   from_region: "us-east-1",
                   node: "127.0.0.1",
                   region: "us-east-1",
                   latency: local_latency,
                   response: {:ok, {:pong, "us-east-1"}}
                 } = us_us_payload}},
               {%Task{},
                {:ok,
                 %Payload{
                   from_node: "127.0.0.1",
                   from_region: "us-east-1",
                   node: "127.0.0.1",
                   region: "ap-southeast-2",
                   latency: remote_latency,
                   response: {:ok, {:pong, "ap-southeast-2"}}
                 } = us_ap_payload}}
             ] = Latency.ping()

      assert is_number(local_latency)
      assert is_number(remote_latency)
      assert local_latency > 0
      assert remote_latency > 0

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "admin:cluster",
        event: "pong",
        payload: ^us_us_payload
      }

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "admin:cluster",
        event: "pong",
        payload: ^us_ap_payload
      }
    end

    test "remotely with a healthy remote node", %{node: node} do
      assert [
               {%Task{},
                {:ok,
                 %Payload{
                   from_node: "127.0.0.1",
                   from_region: "ap-southeast-2",
                   node: "127.0.0.1",
                   region: "ap-southeast-2",
                   latency: local_latency,
                   response: {:ok, {:pong, "ap-southeast-2"}}
                 } = ap_ap_payload}},
               {%Task{},
                {:ok,
                 %Payload{
                   from_node: "127.0.0.1",
                   from_region: "ap-southeast-2",
                   node: "127.0.0.1",
                   region: "us-east-1",
                   latency: remote_latency,
                   response: {:ok, {:pong, "us-east-1"}}
                 } = ap_us_payload}}
             ] = :erpc.call(node, Latency, :ping, [])

      assert is_number(local_latency)
      assert is_number(remote_latency)
      assert local_latency > 0
      assert remote_latency > 0

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "admin:cluster",
        event: "pong",
        payload: ^ap_ap_payload
      }

      assert_receive %Phoenix.Socket.Broadcast{
        topic: "admin:cluster",
        event: "pong",
        payload: ^ap_us_payload
      }
    end

    @tag skip: "Clustered tests creating flakiness, requires time to analyse"
    test "emulate a slow but healthy remote node" do
      assert [{%Task{}, {:ok, %{response: {:ok, {:pong, "not_set"}}}}}] = Latency.ping(5_000, 10_000, 30_000)
    end

    @tag skip: "Clustered tests creating flakiness, requires time to analyse"
    test "emulate an unhealthy remote node" do
      assert [{%Task{}, {:ok, %{response: {:badrpc, :timeout}}}}] = Latency.ping(5_000, 1_000)
    end

    @tag skip: "Clustered tests creating flakiness, requires time to analyse"
    test "no response from our Task for a remote node at all" do
      assert [{%Task{}, nil}] = Latency.ping(10_000, 5_000, 2_000)
    end
  end
end
