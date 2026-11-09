defmodule Realtime.Integration.NodeDrainShutdownTest do
  # async: false due to usage of Clustered
  use ExUnit.Case, async: false
  use TestHelpers

  alias Realtime.Nodes

  test "a node that stops its application is draining on the other nodes until it is gone" do
    region = Nodes.region()
    local = node()

    {:ok, peer} =
      Clustered.start(nil,
        name: :"node_drain_#{System.unique_integer([:positive])}",
        extra_config: [
          # The peer waits this long in prep_stop/1, which leaves time for the checks below.
          {:realtime, :node_drain_settle_ms, 2_000},
          {:realtime, :muster_drain_opts, [settle_ms: 100, timeout_ms: 1_000]}
        ]
      )

    assert_eventually Nodes.region_nodes(region) == Enum.sort([local, peer])
    assert Nodes.draining_nodes(region) == MapSet.new()

    stop = Task.async(fn -> :erpc.call(peer, Application, :stop, [:realtime], 30_000) end)

    # The peer wrote the mark into its own syn scope, so seeing it here means syn replicated it.
    assert_eventually Nodes.draining_nodes(region) == MapSet.new([peer])

    # The peer still gets broadcasts, but no new tenant processes.
    assert Nodes.region_nodes(region) == Enum.sort([local, peer])
    results = for i <- 1..30, do: Nodes.launch_node(region, local, "tenant-#{i}")
    assert Enum.uniq(results) == [local]

    assert :ok = Task.await(stop, 30_000)

    # Syn drops both entries when the process that held them exits with the application.
    assert_eventually Nodes.draining_nodes(region) == MapSet.new() and Nodes.region_nodes(region) == [local]
  end
end
