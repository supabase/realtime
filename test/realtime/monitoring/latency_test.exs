defmodule Realtime.LatencyTest do
  # async: false due to the usage of Clustered mode that interacts with this tests and breaks their expectations
  use Realtime.DataCase, async: false
  alias Realtime.Latency

  describe "pong/0" do
    test "returns pong with region" do
      assert {:ok, {:pong, region}} = Latency.pong()
      assert is_binary(region)
    end
  end

  describe "pong/1" do
    test "returns pong after sleeping for the given latency" do
      assert {:ok, {:pong, _region}} = Latency.pong(0)
    end
  end

  describe "handle_info/2" do
    test "unexpected message does not crash the server" do
      pid = Process.whereis(Latency)
      send(pid, :unexpected_message)
      assert Process.alive?(pid)
    end
  end

  describe "handle_cast/2" do
    test "ping cast triggers a ping and does not crash" do
      pid = Process.whereis(Latency)
      GenServer.cast(pid, {:ping, 0, 5_000, 5_000})
      assert Process.alive?(pid)
    end
  end

  describe "ping/3" do
    setup do
      Node.stop()
      :ok
    end

    @tag skip: "Clustered tests creating flakiness, requires time to analyse"
    test "emulate a healthy remote node" do
      assert [{%Task{}, {:ok, %{response: {:ok, {:pong, "not_set"}}}}}] = Latency.ping()
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
