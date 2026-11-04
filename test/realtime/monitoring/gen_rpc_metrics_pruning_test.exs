defmodule Realtime.GenRpcMetricsPruningTest do
  # Async false due to Clustered usage.
  #
  # GenRpcMetrics maps sockets to nodes by IP address, and every test peer is on 127.0.0.1.
  # It can only tell the nodes apart when one peer is connected, so this test has a module of
  # its own with a peer of its own.
  use ExUnit.Case, async: false

  alias Realtime.GenRpcMetrics

  @peer :gen_rpc_metrics_pruning

  test "drops the accumulator for a node that leaves the cluster" do
    :ok = :net_kernel.monitor_nodes(true)
    {:ok, node} = Clustered.start(nil, name: @peer)

    Realtime.GenRpc.call(node, String, :to_integer, ["25"], key: 1)
    Realtime.GenRpc.call(node, String, :to_integer, ["25"], key: 2)
    GenRpcMetrics.info()
    assert Map.has_key?(:sys.get_state(GenRpcMetrics).totals, node)

    # The peer is stopped, not disconnected. The cluster reconnects a node that is only
    # disconnected within milliseconds, because Muster, syn and PubSub send to it again, so a
    # poll can still list it. A stopped node cannot come back.
    :ok = stop_supervised({:peer, TestEnv.peer_name(@peer)})
    assert_receive {:nodedown, ^node}, 5_000

    # A poll rebuilds `totals` from the live node set, so a node that has left the cluster is
    # pruned instead of accumulating forever.
    GenRpcMetrics.info()
    refute Map.has_key?(:sys.get_state(GenRpcMetrics).totals, node)
  end
end
