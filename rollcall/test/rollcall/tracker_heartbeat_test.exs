defmodule Rollcall.TrackerHeartbeatTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Rollcall.TraceHelpers

  import Rollcall.NetworkHelpers
  import Rollcall.Tracker.Messages, only: [request: 1, snapshot: 3, stamp: 2, wire_entry: 4]

  # A tick counts one quiet period for each peer and sends one heartbeat. The
  # first heartbeat is a snapshot. The next heartbeats are diffs. The tests
  # start trackers with the timer off and send the ticks. The test process is a
  # peer on the fake node `@probe`. It receives what the tracker sends.

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
      assert entries == [wire_entry("partition", ref, "key", %{a: 1})]
    end

    test "sends only the local entries when the view holds the entries of a peer", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      tracker = start_node(scope, network, @node_a)
      ref = track(tracker, start_client(), "partition", "key", %{a: 1})
      send_from_probe(probe, snapshot(self(), stamp(1, 1), [wire_entry("partition", "peer-ref", "peer-key", %{b: 2})]))
      sync(tracker)

      tick(tracker)

      assert {:snapshot, _, _, entries} = receive_message(probe)
      assert entries == [wire_entry("partition", ref, "key", %{a: 1})]
    end

    test "sends only the new entry after a track replaces an entry", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      tracker = start_node(scope, network, @node_a)
      client = start_client()
      ref_1 = track(tracker, client, "partition", "key", %{a: 1})
      ref_2 = track(tracker, client, "partition", "key", %{a: 2})

      tick(tracker)

      assert {:snapshot, _, {:stamp, _, 2}, entries} = receive_message(probe)
      assert entries == [wire_entry("partition", ref_2, "key", %{a: 2, rc_prev_ref: ref_1})]
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

    test "sends an empty diff when nothing changed since the last heartbeat", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      tracker = start_node(scope, network, @node_a)
      track(tracker, start_client(), "partition", "key")

      tick(tracker, 2)

      assert {:snapshot, _, {:stamp, incarnation, 1}, [_entry]} = receive_message(probe)
      assert {:diff, origin, {:stamp, ^incarnation, 1}, 1, [], []} = receive_message(probe)
      assert node(origin) == @node_a
    end

    test "sends the entries that changed since the last heartbeat", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      tracker = start_node(scope, network, @node_a)
      client = start_client()
      ref_1 = track(tracker, client, "partition", "key_1")
      tick(tracker)
      ref_2 = track(tracker, client, "partition", "key_2", %{b: 2})
      untrack(tracker, client, "partition", "key_1")

      tick(tracker)

      assert {:snapshot, _, {:stamp, _, 1}, [_entry]} = receive_message(probe)
      assert {:diff, _, {:stamp, _, 3}, 1, joins, leaves} = receive_message(probe)
      assert joins == [wire_entry("partition", ref_2, "key_2", %{b: 2})]
      assert leaves == [ref_1]
    end

    test "sends the leave of a client that exits in the next diff", %{scope: scope, network: network, probe: probe} do
      check_trace(
        fn ->
          tracker = start_node(scope, network, @node_a)
          client = start_client()
          ref = track(tracker, client, "partition", "key")
          tick(tracker)

          wait_for_event %{"$kind": :rollcall_tracker_pid_down, scope: ^scope} do
            Process.exit(client, :kill)
          end

          tick(tracker)
          ref
        end,
        fn ref, _trace ->
          assert {:snapshot, _, {:stamp, _, 1}, [_entry]} = receive_message(probe)
          assert {:diff, _, {:stamp, _, 2}, 1, [], [^ref]} = receive_message(probe)
        end
      )
    end

    test "sends one join and one leave when a track replaces an entry after a heartbeat", %{
      scope: scope,
      network: network,
      probe: probe
    } do
      tracker = start_node(scope, network, @node_a)
      client = start_client()
      ref_1 = track(tracker, client, "partition", "key", %{a: 1})
      tick(tracker)
      ref_2 = track(tracker, client, "partition", "key", %{a: 2})

      tick(tracker)

      assert {:snapshot, _, _, _} = receive_message(probe)
      assert {:diff, _, {:stamp, _, 2}, 1, joins, leaves} = receive_message(probe)
      assert joins == [wire_entry("partition", ref_2, "key", %{a: 2, rc_prev_ref: ref_1})]
      assert leaves == [ref_1]
    end

    test "sends no entry that joined and left in one period", %{scope: scope, network: network, probe: probe} do
      tracker = start_node(scope, network, @node_a)
      client = start_client()
      tick(tracker)
      track(tracker, client, "partition", "key")
      untrack(tracker, client, "partition", "key")

      tick(tracker)

      assert {:snapshot, _, {:stamp, _, 0}, []} = receive_message(probe)
      assert {:diff, _, {:stamp, _, 2}, 0, [], []} = receive_message(probe)
    end

    test "sends no entry of a peer in the diff", %{scope: scope, network: network, probe: probe} do
      tracker = start_node(scope, network, @node_a)
      track(tracker, start_client(), "partition", "key")
      tick(tracker)
      send_from_probe(probe, snapshot(self(), stamp(1, 1), [wire_entry("partition", "peer-ref", "peer-key", %{b: 2})]))
      sync(tracker)

      tick(tracker)

      assert {:snapshot, _, _, [_entry]} = receive_message(probe)
      assert {:diff, _, {:stamp, _, 1}, 1, [], []} = receive_message(probe)
    end

    test "sends the same diff after a reply to a request", %{scope: scope, network: network, probe: probe} do
      tracker = start_node(scope, network, @node_a)
      client = start_client()
      track(tracker, client, "partition", "key_1")
      tick(tracker)
      ref_2 = track(tracker, client, "partition", "key_2")
      send_from_probe(probe, request(self()))
      sync(tracker)

      tick(tracker)

      assert {:snapshot, _, {:stamp, _, 1}, [_entry]} = receive_message(probe)
      assert {:snapshot, _, {:stamp, _, 2}, [_, _]} = receive_message(probe)
      assert {:diff, _, {:stamp, _, 2}, 1, joins, []} = receive_message(probe)
      assert joins == [wire_entry("partition", ref_2, "key_2", %{})]
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

    test "traces a diff with the version, the base and the refs", %{scope: scope, network: network} do
      check_trace(
        fn ->
          tracker = start_node(scope, network, @node_a)
          client = start_client()
          ref_1 = track(tracker, client, "partition", "key_1")
          tick(tracker)
          ref_2 = track(tracker, client, "partition", "key_2")
          untrack(tracker, client, "partition", "key_1")

          tick(tracker)
          {tracker, ref_1, ref_2}
        end,
        fn {tracker, ref_1, ref_2}, trace ->
          heartbeats =
            trace
            |> events(:rollcall_tracker_heartbeat_sent, scope)
            |> Enum.filter(&(&1.origin == tracker))

          assert [
                   %{kind: :snapshot, version: 1, refs: [^ref_1]},
                   %{kind: :diff, version: 3, from: 1, joins: [^ref_2], leaves: [^ref_1]}
                 ] = heartbeats
        end
      )
    end

    test "sends the heartbeat in the tick that purges a peer", %{scope: scope, network: network, probe: probe} do
      check_trace(
        fn ->
          tracker = start_node(scope, network, @node_a, silence_threshold: 2)
          send_from_probe(probe, snapshot(self(), stamp(1, 1), [wire_entry("partition", "ref", "key", %{})]))

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
      assert {:diff, _, _, 0, [], []} = receive_message(probe)
    end
  end
end
