defmodule Rollcall.TrackerGoodbyeTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Rollcall.TraceHelpers

  import Rollcall.NetworkHelpers

  # A tracker that stops sends a goodbye: a snapshot with no entries. The stamp
  # of the goodbye has the version after the last change plus one. A peer that
  # holds the last heartbeat then sees a newer stamp. A tracker that crashes
  # sends nothing.

  @node_a :a@host
  @probe :probe@host

  setup %{scope: scope} do
    network = start_network()
    probe = join_probe(network, scope, @probe)
    {:ok, network: network, probe: probe}
  end

  test "the end of the grace period sends the goodbye and stops the tracker", %{
    scope: scope,
    network: network,
    probe: probe
  } do
    check_trace(
      fn ->
        tracker = start_node(scope, network, @node_a)
        client = start_client()
        track(tracker, client, "partition", "key")
        untrack(tracker, client, "partition", "key")

        monitor = Process.monitor(tracker)
        expire_grace(tracker)
        assert_receive {:DOWN, ^monitor, :process, ^tracker, :normal}
        tracker
      end,
      fn tracker, trace ->
        assert {:snapshot, origin, {:stamp, _incarnation, 3}, []} = receive_message(probe)
        assert node(origin) == @node_a

        assert [%{origin: ^tracker, version: 3}] = expect_events(trace, :rollcall_tracker_goodbye_sent, scope, 1)
      end
    )
  end

  test "a supervisor shutdown sends the goodbye when the tracker holds entries", %{
    scope: scope,
    network: network,
    probe: probe
  } do
    tracker = start_node(scope, network, @node_a)
    track(tracker, start_client(), "partition", "key")

    stop_node({scope, @node_a})

    assert {:snapshot, _origin, {:stamp, _incarnation, 2}, []} = receive_message(probe)
  end

  test "a goodbye has a newer stamp than the heartbeat before it", %{
    scope: scope,
    network: network,
    probe: probe
  } do
    tracker = start_node(scope, network, @node_a)
    track(tracker, start_client(), "partition", "key")
    tick(tracker)

    stop_node({scope, @node_a})

    assert {:snapshot, _, {:stamp, incarnation, heartbeat_version}, [_entry]} = receive_message(probe)
    assert {:snapshot, _, {:stamp, ^incarnation, goodbye_version}, []} = receive_message(probe)
    assert goodbye_version > heartbeat_version
  end

  test "a kill sends nothing", %{scope: scope, network: network} do
    tracker = start_node(scope, network, @node_a)
    track(tracker, start_client(), "partition", "key")

    kill_node(tracker)

    refute_receive {:in_memory, _, _, _}, 100
  end
end
