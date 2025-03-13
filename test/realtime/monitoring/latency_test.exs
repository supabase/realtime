defmodule Realtime.LatencyTest do
  # async: false due to the usage of Clustered mode that interacts with this tests and breaks their expectations
  use Realtime.DataCase, async: false
  alias Realtime.Latency

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
