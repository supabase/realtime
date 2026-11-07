defmodule Rollcall.TrackerPublishTest do
  use Rollcall.Case, async: true

  import Rollcall.NetworkHelpers
  import Rollcall.Tracker.Messages, only: [diff: 5, snapshot: 3, stamp: 2, wire_entry: 4]
  import Rollcall.TrackerHelpers, only: [remote_pid: 2]

  alias Rollcall.Tracker
  alias Rollcall.Transport.PublishProbe

  @node_a :a@host
  @probe :probe@host

  setup %{scope: scope} do
    network = start_network()
    tracker = start_node(scope, network, @node_a, silence_threshold: 2)
    :ok = subscribe(network, scope, @node_a, "p1")
    :ok = subscribe(network, scope, @node_a, "p2")

    {:ok, network: network, tracker: tracker}
  end

  describe "a local change" do
    test "a track publishes a diff with the join", %{tracker: tracker} do
      ref = track(tracker, start_client(), "p1", "key", %{n: 1})

      assert {[{^ref, "key", %{n: 1}}], []} = receive_diff("p1")
    end

    test "a track of the same key publishes one diff with the leave and the join", %{tracker: tracker} do
      client = start_client()
      old = track(tracker, client, "p1", "key", %{n: 1})
      receive_diff("p1")

      new = track(tracker, client, "p1", "key", %{n: 2})

      assert {[{^new, "key", %{n: 2, rc_prev_ref: ^old}}], [{^old, "key", %{n: 1}}]} = receive_diff("p1")
    end

    test "an untrack publishes a diff with the leave, its key and its meta", %{tracker: tracker} do
      client = start_client()
      ref = track(tracker, client, "p1", "key", %{n: 1})
      receive_diff("p1")

      untrack(tracker, client, "p1", "key")

      assert {[], [{^ref, "key", %{n: 1}}]} = receive_diff("p1")
    end

    test "the exit of a tracked process publishes a diff with the leave", %{tracker: tracker} do
      client = spawn(fn -> Process.sleep(:infinity) end)
      ref = track(tracker, client, "p1", "key", %{})
      receive_diff("p1")

      Process.exit(client, :kill)

      assert {[], [{^ref, "key", %{}}]} = receive_diff("p1")
    end
  end

  describe "a change from a peer" do
    setup %{scope: scope, network: network} do
      {:ok, probe: join_probe(network, scope, @probe)}
    end

    test "a snapshot publishes one diff for each partition", %{probe: probe} do
      send_from_probe(
        probe,
        snapshot(self(), stamp(1, 1), [wire_entry("p1", "k1", "a", %{n: 1}), wire_entry("p2", "k2", "b", %{})])
      )

      assert {[{"a", "k1", %{n: 1}}], []} = receive_diff("p1")
      assert {[{"b", "k2", %{}}], []} = receive_diff("p2")
    end

    test "a diff publishes its joins and its leaves", %{probe: probe} do
      send_from_probe(probe, snapshot(self(), stamp(1, 1), [wire_entry("p1", "k1", "a", %{})]))
      receive_diff("p1")

      send_from_probe(probe, diff(self(), stamp(1, 2), 1, [wire_entry("p1", "k2", "b", %{n: 1})], ["a"]))

      assert {[{"b", "k2", %{n: 1}}], [{"a", "k1", %{}}]} = receive_diff("p1")
    end

    test "the purge of a silent peer publishes its entries as leaves", %{probe: probe, tracker: tracker} do
      send_from_probe(
        probe,
        snapshot(self(), stamp(1, 1), [wire_entry("p1", "k1", "a", %{}), wire_entry("p1", "k2", "b", %{})])
      )

      receive_diff("p1")

      tick(tracker, 2)

      assert {[], leaves} = receive_diff("p1")
      assert Enum.sort(leaves) == [{"a", "k1", %{}}, {"b", "k2", %{}}]
    end
  end

  describe "a change that does nothing" do
    test "publishes no diff", %{tracker: tracker, scope: scope, network: network} do
      probe = join_probe(network, scope, @probe)
      send_from_probe(probe, snapshot(self(), stamp(1, 1), [wire_entry("p1", "k1", "a", %{})]))
      receive_diff("p1")

      untrack(tracker, start_client(), "p1", "missing")
      send_from_probe(probe, snapshot(self(), stamp(1, 2), [wire_entry("p1", "k1", "a", %{})]))
      tick(tracker, 1)

      refute_receive {:rollcall_diff, _, _, _}, 100
    end
  end

  describe "the order" do
    test "the view holds the change when the tracker publishes the diff", %{scope: scope, rollcall: rollcall} do
      tracker =
        start_supervised!(
          {Tracker,
           {scope,
            name: rollcall, heartbeat_period_in_ms: :manual, transport: {PublishProbe, to: self(), rollcall: rollcall}}}
        )

      {:ok, ref} = Rollcall.track(rollcall, self(), scope, "p1", "key", %{})
      assert_receive {:published, "p1", {[{^ref, "key", %{}}], []}, [{^ref, "key", %{}}]}

      :ok = Rollcall.untrack(rollcall, self(), scope, "p1", "key")
      assert_receive {:published, "p1", {[], [{^ref, "key", %{}}]}, []}

      origin = remote_pid(@node_a, 1)
      send(tracker, {:deliver, scope, snapshot(origin, stamp(1, 1), [wire_entry("p1", "k", "a", %{})])})
      assert_receive {:published, "p1", {[{"a", "k", %{}}], []}, [{"a", "k", %{}}]}
    end
  end
end
