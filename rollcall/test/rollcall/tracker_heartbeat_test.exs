defmodule Rollcall.TrackerHeartbeatTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Rollcall.TraceHelpers

  import Rollcall.NetworkHelpers
  import Rollcall.Tracker.Messages, only: [snapshot: 3, stamp: 2, wire_entry: 4]

  # A tick counts one quiet period for each peer and sends one snapshot. The
  # tests start trackers with the timer off and send the ticks. The test process
  # is a peer on the fake node `@probe`. It receives what the tracker sends.

  @node_a :a@host
  @probe :probe@host

  setup %{scope: scope} do
    network = start_network()
    probe = join_probe(network, scope, @probe)
    {:ok, network: network, probe: probe}
  end

  describe "tick" do
    test "sends a snapshot of the local entries", %{scope: scope, network: network, probe: probe} do
      tracker = start_node(scope, network, @node_a)
      ref = track(tracker, start_client(), "partition", "key", %{a: 1})

      tick(tracker)

      assert {:snapshot, origin, {:stamp, incarnation, 1}, entries} = receive_message(probe)
      assert node(origin) == @node_a
      assert incarnation == tracker_state(tracker).incarnation
      assert entries == [wire_entry("partition", "key", ref, %{a: 1})]
    end

    test "sends a snapshot with no entries when the tracker holds none", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      tracker = start_node(scope, network, @node_a)

      tick(tracker)

      assert {:snapshot, _origin, {:stamp, _incarnation, 0}, []} = receive_message(probe)
    end

    test "sends a snapshot on each tick", %{scope: scope, network: network, probe: probe} do
      tracker = start_node(scope, network, @node_a)
      track(tracker, start_client(), "partition", "key")

      tick(tracker, 2)

      assert {:snapshot, _, stamp, entries} = receive_message(probe)
      assert {:snapshot, _, ^stamp, ^entries} = receive_message(probe)
    end

    test "sends the version after each change", %{scope: scope, network: network, probe: probe} do
      tracker = start_node(scope, network, @node_a)
      client = start_client()
      track(tracker, client, "partition", "key")
      tick(tracker)
      untrack(tracker, client, "partition", "key")
      tick(tracker)

      assert {:snapshot, _, {:stamp, _, 1}, [_entry]} = receive_message(probe)
      assert {:snapshot, _, {:stamp, _, 2}, []} = receive_message(probe)
    end

    test "sends the version after a client exits", %{scope: scope, network: network, probe: probe} do
      check_trace(
        fn ->
          tracker = start_node(scope, network, @node_a)
          client = start_client()
          track(tracker, client, "partition", "key")
          tick(tracker)

          wait_for_event %{"$kind": :rollcall_tracker_pid_down, scope: ^scope} do
            Process.exit(client, :kill)
          end

          tick(tracker)
        end,
        fn _, _trace ->
          assert {:snapshot, _, {:stamp, _, 1}, [_entry]} = receive_message(probe)
          assert {:snapshot, _, {:stamp, _, 2}, []} = receive_message(probe)
        end
      )
    end

    test "emits one event for each tick however many peers exist", %{scope: scope, network: network} do
      check_trace(
        fn ->
          tracker = start_node(scope, network, @node_a)
          start_node(scope, network, :b@host)
          start_node(scope, network, :c@host)
          ref = track(tracker, start_client(), "partition", "key")

          tick(tracker)
          {tracker, ref}
        end,
        fn {tracker, ref}, trace ->
          heartbeats = events(trace, :rollcall_tracker_heartbeat_sent, scope)

          assert [%{kind: :snapshot, version: 1, refs: [^ref]}] = Enum.filter(heartbeats, &(&1.origin == tracker))
        end
      )
    end

    test "sends the heartbeat in the tick that purges a peer", %{scope: scope, network: network, probe: probe} do
      check_trace(
        fn ->
          tracker = start_node(scope, network, @node_a, silence_threshold: 2)
          send_from_probe(probe, snapshot(self(), stamp(1, 1), [wire_entry("partition", "key", "ref", %{})]))

          tick(tracker)
          tick(tracker)
          tracker
        end,
        fn tracker, trace ->
          assert [%{node: @probe}] = expect_events(trace, :rollcall_tracker_peer_purged, scope, 1)

          heartbeats = events(trace, :rollcall_tracker_heartbeat_sent, scope)
          assert length(Enum.filter(heartbeats, &(&1.origin == tracker))) == 2
        end
      )
    end

    test "sends a heartbeat on its own when the period is a number", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      start_node(scope, network, @node_a, heartbeat_period_in_ms: 20)

      assert {:snapshot, _, _, []} = receive_message(probe)
      assert {:snapshot, _, _, []} = receive_message(probe)
    end
  end
end
