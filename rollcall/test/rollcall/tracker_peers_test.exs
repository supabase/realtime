defmodule Rollcall.TrackerPeersTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Rollcall.TraceHelpers

  import Rollcall.PeerHelpers
  import Rollcall.TrackerHelpers
  import Rollcall.Tracker.Messages, only: [diff: 5, request: 1, snapshot: 3, stamp: 2, wire_entry: 4]

  alias Rollcall.Tracker
  alias Rollcall.Tracker.Local
  alias Rollcall.Tracker.Peer

  # The tracker keeps one peer record for each node. It finds the record with
  # `node(origin)`. A snapshot or a diff from an unknown node creates the
  # record. A request does not. A tick counts a quiet period for each record,
  # and a record that reaches the threshold is deleted.
  #
  # The tests send `{:deliver, message}` and `:tick` to the tracker, and wait
  # for the tracker to handle them. The origins are pids on fake nodes.

  @node_a :a@host
  @node_b :b@host
  @threshold 3

  @message :rollcall_tracker_peer_message
  @purged :rollcall_tracker_peer_purged

  describe "a message from an unknown node" do
    test "a snapshot creates the record for the node of the origin", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a", "b"])))
          peers(scope)
        end,
        fn peers, trace ->
          assert Map.keys(peers) == [@node_a]
          assert refs(peers[@node_a]) == ["a", "b"]
          assert Peer.origin(peers[@node_a]) == origin

          [event] = expect_events(trace, @message, scope, 1)
          assert %{node: @node_a, leaves: [], behind: false} = event
          assert Enum.sort(event.joins) == ["a", "b"]
        end
      )
    end

    test "a diff creates a record that is behind", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, diff(origin, stamp(1, 4), 3, entries(["a"]), []))
          peers(scope)
        end,
        fn peers, trace ->
          assert Map.keys(peers) == [@node_a]
          assert refs(peers[@node_a]) == []
          assert Peer.behind?(peers[@node_a])

          [event] = expect_events(trace, @message, scope, 1)
          assert %{node: @node_a, joins: [], leaves: [], behind: true} = event
        end
      )
    end

    test "a request creates no record", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, request(origin))
          tick(tracker, @threshold)
          peers(scope)
        end,
        fn peers, trace ->
          assert peers == %{}
          expect_events(trace, [@message, @purged], scope, 0)
        end
      )
    end
  end

  describe "a message from the local node" do
    test "creates no record and emits no event", %{scope: scope} do
      origin = self()

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a"])))
          deliver(tracker, diff(origin, stamp(1, 4), 3, entries(["b"]), []))
          deliver(tracker, request(origin))
          peers(scope)
        end,
        fn peers, trace ->
          assert peers == %{}
          expect_events(trace, @message, scope, 0)
        end
      )
    end

    test "does not change a record of another node", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a"])))
          deliver(tracker, snapshot(self(), stamp(9, 9), entries(["z"])))
          peers(scope)
        end,
        fn peers, trace ->
          assert Map.keys(peers) == [@node_a]
          assert refs(peers[@node_a]) == ["a"]
          expect_events(trace, @message, scope, 1)
        end
      )
    end
  end

  describe "a message from a known node" do
    test "the event holds the joins and the leaves of the change", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a", "b"])))
          deliver(tracker, diff(origin, stamp(1, 4), 3, entries(["c"]), ["a"]))
          peers(scope)
        end,
        fn peers, trace ->
          assert refs(peers[@node_a]) == ["b", "c"]

          [_first, second] = expect_events(trace, @message, scope, 2)
          assert %{node: @node_a, joins: ["c"], leaves: ["a"], behind: false} = second
        end
      )
    end

    test "the event shows behind after a gap", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a"])))
          deliver(tracker, diff(origin, stamp(1, 6), 5, entries(["b"]), []))
          peers(scope)
        end,
        fn peers, trace ->
          assert Peer.behind?(peers[@node_a])
          assert refs(peers[@node_a]) == ["a"]

          [_first, second] = expect_events(trace, @message, scope, 2)
          assert %{joins: [], leaves: [], behind: true} = second
        end
      )
    end

    test "two origins on one node share one record", %{scope: scope} do
      old_origin = remote_pid(@node_a, 1)
      new_origin = remote_pid(@node_a, 2)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(old_origin, stamp(1, 3), entries(["a"])))
          deliver(tracker, snapshot(new_origin, stamp(2, 0), entries(["b"])))
          peers(scope)
        end,
        fn peers, trace ->
          assert Map.keys(peers) == [@node_a]
          assert refs(peers[@node_a]) == ["b"]
          assert Peer.origin(peers[@node_a]) == new_origin

          [_first, second] = expect_events(trace, @message, scope, 2)
          assert %{joins: ["b"], leaves: ["a"]} = second
        end
      )
    end

    test "a stale message from an old origin does not change the origin", %{scope: scope} do
      old_origin = remote_pid(@node_a, 1)
      new_origin = remote_pid(@node_a, 2)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(new_origin, stamp(2, 0), entries(["b"])))
          deliver(tracker, snapshot(old_origin, stamp(1, 3), entries(["a"])))
          peers(scope)
        end,
        fn peers, trace ->
          assert refs(peers[@node_a]) == ["b"]
          assert Peer.origin(peers[@node_a]) == new_origin

          [_first, second] = expect_events(trace, @message, scope, 2)
          assert %{joins: [], leaves: []} = second
        end
      )
    end

    test "origins on two nodes get separate records", %{scope: scope} do
      origin_a = remote_pid(@node_a, 1)
      origin_b = remote_pid(@node_b, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin_a, stamp(1, 3), entries(["a"])))
          deliver(tracker, snapshot(origin_b, stamp(1, 3), entries(["b"])))
          peers(scope)
        end,
        fn peers, _trace ->
          assert peers |> Map.keys() |> Enum.sort() == [@node_a, @node_b]
          assert refs(peers[@node_a]) == ["a"]
          assert refs(peers[@node_b]) == ["b"]
        end
      )
    end
  end

  describe "tick" do
    test "does nothing when the tracker has no peers", %{scope: scope} do
      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          tick(tracker, @threshold)
          Process.alive?(tracker)
        end,
        fn alive?, trace ->
          assert alive?
          expect_events(trace, [@message, @purged], scope, 0)
        end
      )
    end

    test "deletes the record after the threshold and emits the leaves", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a", "b"])))
          tick(tracker, @threshold - 1)
          kept = peers(scope)
          tick(tracker, 1)
          {kept, peers(scope)}
        end,
        fn {kept, peers}, trace ->
          assert Map.keys(kept) == [@node_a]
          assert peers == %{}

          [event] = expect_events(trace, @purged, scope, 1)
          assert %{node: @node_a, joins: []} = event
          assert Enum.sort(event.leaves) == ["a", "b"]
        end
      )
    end

    test "a message restarts the count", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a"])))
          tick(tracker, @threshold - 1)
          deliver(tracker, snapshot(origin, stamp(1, 2), []))
          tick(tracker, @threshold - 1)
          peers(scope)
        end,
        fn peers, trace ->
          assert Map.keys(peers) == [@node_a]
          expect_events(trace, @purged, scope, 0)
        end
      )
    end

    test "a request from a known node restarts the count", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a"])))
          tick(tracker, @threshold - 1)
          deliver(tracker, request(origin))
          tick(tracker, @threshold - 1)
          peers(scope)
        end,
        fn peers, trace ->
          assert Map.keys(peers) == [@node_a]
          expect_events(trace, @purged, scope, 0)
        end
      )
    end

    test "counts each node on its own", %{scope: scope} do
      origin_a = remote_pid(@node_a, 1)
      origin_b = remote_pid(@node_b, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin_a, stamp(1, 3), entries(["a"])))
          tick(tracker, @threshold - 1)
          deliver(tracker, snapshot(origin_b, stamp(1, 3), entries(["b"])))
          tick(tracker, 1)
          peers(scope)
        end,
        fn peers, trace ->
          assert Map.keys(peers) == [@node_b]
          assert [%{node: @node_a, leaves: ["a"]}] = expect_events(trace, @purged, scope, 1)
        end
      )
    end

    test "a snapshot after a purge creates a new record even with the old stamp", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a"])))
          tick(tracker, @threshold)
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a"])))
          peers(scope)
        end,
        fn peers, trace ->
          assert refs(peers[@node_a]) == ["a"]

          [_first, second] = expect_events(trace, @message, scope, 2)
          assert %{joins: ["a"], leaves: []} = second
        end
      )
    end

    test "a purge does not change the local entries or the version", %{scope: scope} do
      origin = remote_pid(@node_a, 1)

      check_trace(
        fn ->
          tracker = start_tracker(scope, @threshold)
          {:ok, ref} = Rollcall.track(self(), scope, "partition", "key", %{})
          deliver(tracker, snapshot(origin, stamp(1, 3), entries(["a"])))
          tick(tracker, @threshold)
          {ref, Tracker.get_state(scope)}
        end,
        fn {ref, state}, _trace ->
          assert state.version == 1
          assert [%{ref: ^ref}] = Local.entries(state.local, "partition")
          assert state.peers == %{}
        end
      )
    end
  end

  defp entries(refs) do
    Enum.map(refs, &wire_entry("partition", "key", &1, %{}))
  end

  defp deliver(tracker, message) do
    GenServer.cast(tracker, {:deliver, message})
    sync(tracker)
  end

  defp tick(tracker, times) do
    for _ <- 1..times, do: send(tracker, :tick)
    sync(tracker)
  end

  # A call returns after the tracker handled every earlier message.
  defp sync(tracker) do
    :sys.get_state(tracker)
    :ok
  end

  defp peers(scope), do: Tracker.get_state(scope).peers
end
