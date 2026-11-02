defmodule Rollcall.TrackerTransportTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Rollcall.TraceHelpers

  import Rollcall.NetworkHelpers
  import Rollcall.PeerHelpers, only: [refs: 1, mark_tuple: 1]
  import Rollcall.Tracker.Messages, only: [snapshot: 3, stamp: 2, wire_entry: 4]

  # The tracker takes a transport as the option `:transport`. It joins the scope
  # when it starts. The transport delivers its own raw messages to the mailbox of
  # the tracker. The tracker passes each message that no other clause matches to
  # `unwrap/2`.

  @node_a :a@host
  @probe :probe@host

  setup do
    {:ok, network: start_network()}
  end

  describe "start" do
    test "joins the scope through the transport and emits an event", %{scope: scope, network: network} do
      check_trace(
        fn -> start_node(scope, network, @node_a) end,
        fn tracker, trace ->
          assert [event] = expect_events(trace, :rollcall_tracker_joined, scope, 1)
          assert %{origin: ^tracker} = event
        end
      )
    end

    test "registers the tracker under the option :name", %{scope: scope, network: network} do
      tracker = start_node(scope, network, @node_a, name: :named_tracker)

      assert Process.whereis(:named_tracker) == tracker
    end

    test "runs two trackers for one scope", %{scope: scope, network: network} do
      a = start_node(scope, network, @node_a)
      b = start_node(scope, network, :b@host)

      assert a != b
      assert Process.alive?(a)
      assert Process.alive?(b)
    end
  end

  describe "a message from the transport" do
    test "creates the record of the node of the sender", %{scope: scope, network: network} do
      tracker = start_node(scope, network, @node_a)
      probe = join_probe(network, scope, @probe)

      send_from_probe(probe, snapshot(self(), stamp(1, 3), [wire_entry("partition", "key", "ref", %{})]))
      sync(tracker)

      assert Map.keys(tracker_state(tracker).peers) == [@probe]
      assert refs(peer(tracker, @probe)) == ["ref"]
      assert mark_tuple(peer(tracker, @probe)) == {1, 3}
    end

    test "does not reach a tracker of another scope", %{scope: scope, network: network} do
      tracker = start_node(unique_scope(), network, @node_a)
      probe = join_probe(network, scope, @probe)

      send_from_probe(probe, snapshot(self(), stamp(1, 3), []))
      sync(tracker)

      assert tracker_state(tracker).peers == %{}
    end
  end

  describe "a message that the transport ignores" do
    test "changes nothing and does not stop the tracker", %{scope: scope, network: network} do
      tracker = start_node(scope, network, @node_a)
      before = tracker_state(tracker)

      send(tracker, :junk)
      send(tracker, {:in_memory_unknown, scope})

      assert tracker_state(tracker) == before
      assert Process.alive?(tracker)
    end
  end
end
