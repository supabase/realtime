defmodule Rollcall.Tracker.PeerTest do
  use ExUnit.Case, async: true

  import Rollcall.PeerHelpers
  import Rollcall.Tracker.Messages, only: [diff: 5, request: 1, snapshot: 3, stamp: 2, wire_entry: 4]

  alias Rollcall.Tracker.Peer

  setup do
    %{origin: new_pid(), other_origin: new_pid()}
  end

  describe "new/1" do
    test "a snapshot gives the replica, the mark and the joins", %{origin: origin} do
      {peer, changes} = Peer.new(snapshot(origin, stamp(1, 3), entries(["a", "b"])))

      assert refs(peer) == ["a", "b"]
      assert mark_tuple(peer) == {1, 3}
      assert joins(changes) == ["a", "b"]
      assert leaves(changes) == []
      refute Peer.behind?(peer)
      assert Peer.origin(peer) == origin
    end

    test "a diff gives an empty replica that is behind", %{origin: origin} do
      {peer, changes} = Peer.new(diff(origin, stamp(1, 4), 3, entries(["a"]), []))

      assert refs(peer) == []
      assert mark_tuple(peer) == nil
      assert Peer.behind?(peer)
      assert Peer.origin(peer) == origin
      assert_no_changes(changes)
    end
  end

  describe "the payload of an entry" do
    test "a snapshot holds the id of each entry and returns the partition, key and meta in the joins",
         %{origin: origin} do
      wire = [
        wire_entry("partition_1", "a", "key_1", %{a: 1}),
        wire_entry("partition_2", "b", "key_1", %{b: 2}),
        wire_entry("partition_1", "c", "key_2", %{})
      ]

      {peer, changes} = Peer.new(snapshot(origin, stamp(1, 3), wire))

      assert Enum.sort(Peer.entries(peer)) == [{"partition_1", "a"}, {"partition_1", "c"}, {"partition_2", "b"}]

      assert Enum.sort(changes.joins) == [
               {"partition_1", "a", "key_1", %{a: 1}},
               {"partition_1", "c", "key_2", %{}},
               {"partition_2", "b", "key_1", %{b: 2}}
             ]
    end

    test "a diff join returns the partition, key and meta in the joins", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, [])
      joined = wire_entry("partition_2", "b", "key_1", %{b: 2})

      {_peer, changes} = Peer.apply(peer, diff(origin, stamp(1, 4), 3, [joined], []))

      assert changes.joins == [{"partition_2", "b", "key_1", %{b: 2}}]
    end

    test "a leave removes the entry with its ref and keeps the entry with the same key",
         %{origin: origin} do
      first = wire_entry("partition", "a", "key", %{a: 1})
      second = wire_entry("partition", "b", "key", %{a: 2})
      {peer, _changes} = Peer.new(snapshot(origin, stamp(1, 3), [first, second]))

      {peer, changes} = Peer.apply(peer, diff(origin, stamp(1, 4), 3, [], ["a"]))

      assert Peer.entries(peer) == [{"partition", "b"}]
      assert changes.leaves == [{"partition", "a"}]
    end

    test "a wire entry of the wrong shape is rejected", %{origin: origin} do
      assert catch_error(Peer.new(snapshot(origin, stamp(1, 3), [{"partition", "key", "a"}])))
    end
  end

  # A diff names a leave by its ref. The replica gives the partition. Each path
  # that returns leaves builds the key from the replica, so each path has a test.
  describe "the partition of a leave" do
    setup %{origin: origin} do
      wire = [
        wire_entry("p1", "a", "k1", %{}),
        wire_entry("p2", "b", "k2", %{}),
        wire_entry("p1", "c", "k3", %{})
      ]

      {peer, _changes} = Peer.new(snapshot(origin, stamp(1, 3), wire))

      %{peer: peer}
    end

    test "a diff leave takes the partition from the replica", %{origin: origin, peer: peer} do
      {_peer, changes} = Peer.apply(peer, diff(origin, stamp(1, 4), 3, [], ["b", "c"]))

      assert leave_ids(changes) == [{"p1", "c"}, {"p2", "b"}]
    end

    test "a snapshot that drops entries returns their partitions", %{origin: origin, peer: peer} do
      kept = wire_entry("p1", "a", "k1", %{})

      {_peer, changes} = Peer.apply(peer, snapshot(origin, stamp(1, 4), [kept]))

      assert leave_ids(changes) == [{"p1", "c"}, {"p2", "b"}]
    end

    test "a purge returns the partition of every entry", %{peer: peer} do
      assert {:purge, changes} = Peer.tick(peer, 1)

      assert leave_ids(changes) == [{"p1", "a"}, {"p1", "c"}, {"p2", "b"}]
    end
  end

  describe "apply/2 with a snapshot" do
    test "a newer version replaces the replica", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a", "b"])

      {peer, changes} = Peer.apply(peer, snapshot(origin, stamp(1, 4), entries(["b", "c"])))

      assert refs(peer) == ["b", "c"]
      assert mark_tuple(peer) == {1, 4}
      assert joins(changes) == ["c"]
      assert leaves(changes) == ["a"]
    end

    test "a newer incarnation replaces the replica when its version is lower", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 9, ["a"])

      {peer, changes} = Peer.apply(peer, snapshot(origin, stamp(2, 0), entries(["b"])))

      assert refs(peer) == ["b"]
      assert mark_tuple(peer) == {2, 0}
      assert joins(changes) == ["b"]
      assert leaves(changes) == ["a"]
    end

    test "a snapshot clears behind", %{origin: origin} do
      {peer, _changes} = Peer.new(diff(origin, stamp(1, 4), 3, [], []))
      assert Peer.behind?(peer)

      {peer, _changes} = Peer.apply(peer, snapshot(origin, stamp(1, 4), entries(["a"])))

      refute Peer.behind?(peer)
      assert refs(peer) == ["a"]
    end

    test "an empty snapshot is a goodbye and removes every entry", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a", "b"])

      {peer, changes} = Peer.apply(peer, snapshot(origin, stamp(1, 4), []))

      assert refs(peer) == []
      assert joins(changes) == []
      assert leaves(changes) == ["a", "b"]
    end

    test "a snapshot with the same stamp is stale", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      assert_unchanged(peer, snapshot(origin, stamp(1, 3), entries(["b"])))
    end

    test "a snapshot with an older version is stale", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      assert_unchanged(peer, snapshot(origin, stamp(1, 2), entries(["b"])))
    end

    test "a snapshot with an older incarnation is stale", %{origin: origin} do
      peer = snapshot_peer(origin, 2, 0, ["a"])

      assert_unchanged(peer, snapshot(origin, stamp(1, 9), entries(["b"])))
    end
  end

  describe "apply/2 with a diff that applies" do
    test "removes the leaves and adds the joins", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a", "b"])

      {peer, changes} =
        Peer.apply(peer, diff(origin, stamp(1, 5), 3, entries(["c"]), ["a"]))

      assert refs(peer) == ["b", "c"]
      assert mark_tuple(peer) == {1, 5}
      assert joins(changes) == ["c"]
      assert leaves(changes) == ["a"]
    end

    test "an entry in the joins and the leaves stays", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      {peer, changes} =
        Peer.apply(peer, diff(origin, stamp(1, 4), 3, entries(["a"]), ["a"]))

      assert refs(peer) == ["a"]
      assert mark_tuple(peer) == {1, 4}
      assert_no_changes(changes)
    end

    test "a leave of an entry that the replica lacks makes no change", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      {peer, changes} = Peer.apply(peer, diff(origin, stamp(1, 4), 3, [], ["z"]))

      assert refs(peer) == ["a"]
      assert_no_changes(changes)
    end

    test "a join of an entry that the replica holds makes no change", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      {peer, changes} = Peer.apply(peer, diff(origin, stamp(1, 4), 3, entries(["a"]), []))

      assert refs(peer) == ["a"]
      assert_no_changes(changes)
    end

    test "an empty diff keeps the mark and changes nothing", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      {peer, changes} = Peer.apply(peer, diff(origin, stamp(1, 3), 3, [], []))

      assert refs(peer) == ["a"]
      assert mark_tuple(peer) == {1, 3}
      refute Peer.behind?(peer)
      assert_no_changes(changes)
    end

    test "does not clear behind", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])
      {peer, _changes} = Peer.apply(peer, diff(origin, stamp(1, 6), 5, [], []))
      assert Peer.behind?(peer)

      {peer, _changes} = Peer.apply(peer, diff(origin, stamp(1, 5), 3, entries(["b"]), []))

      assert refs(peer) == ["a", "b"]
      assert Peer.behind?(peer)
    end
  end

  describe "apply/2 with a diff that does not apply" do
    test "a gap sets behind and changes nothing else", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      {peer, changes} = Peer.apply(peer, diff(origin, stamp(1, 6), 5, entries(["b"]), []))

      assert Peer.behind?(peer)
      assert refs(peer) == ["a"]
      assert mark_tuple(peer) == {1, 3}
      assert_no_changes(changes)
    end

    test "a diff of a newer incarnation is a gap even when from matches the version",
         %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      {peer, changes} = Peer.apply(peer, diff(origin, stamp(2, 4), 3, entries(["b"]), []))

      assert Peer.behind?(peer)
      assert refs(peer) == ["a"]
      assert mark_tuple(peer) == {1, 3}
      assert_no_changes(changes)
    end

    test "a delayed diff applies after a gap", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])
      {peer, _changes} = Peer.apply(peer, diff(origin, stamp(1, 6), 5, [], []))

      {peer, changes} = Peer.apply(peer, diff(origin, stamp(1, 5), 3, entries(["b"]), []))

      assert refs(peer) == ["a", "b"]
      assert mark_tuple(peer) == {1, 5}
      assert joins(changes) == ["b"]
    end

    test "a diff of an older incarnation is stale", %{origin: origin} do
      peer = snapshot_peer(origin, 2, 0, ["a"])

      assert_unchanged(peer, diff(origin, stamp(1, 9), 8, entries(["b"]), []))
    end

    test "a diff of the same incarnation that is not newer is stale", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      assert_unchanged(peer, diff(origin, stamp(1, 2), 1, entries(["b"]), []))
    end
  end

  describe "apply/2 with a request" do
    test "changes nothing", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      assert_unchanged(peer, request(origin))
    end
  end

  describe "apply/2 and the origin" do
    test "a snapshot that replaces the replica sets the origin", %{
      origin: origin,
      other_origin: other_origin
    } do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      {peer, _changes} = Peer.apply(peer, snapshot(other_origin, stamp(2, 0), entries(["b"])))

      assert Peer.origin(peer) == other_origin
    end

    test "a diff that applies sets the origin", %{origin: origin, other_origin: other_origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      {peer, _changes} = Peer.apply(peer, diff(other_origin, stamp(1, 4), 3, [], []))

      assert Peer.origin(peer) == other_origin
    end

    test "a diff that sets behind sets the origin", %{origin: origin, other_origin: other_origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      {peer, _changes} = Peer.apply(peer, diff(other_origin, stamp(2, 4), 3, [], []))

      assert Peer.origin(peer) == other_origin
    end

    test "a stale message does not set the origin", %{origin: origin, other_origin: other_origin} do
      peer = snapshot_peer(origin, 2, 3, ["a"])

      {peer, _changes} = Peer.apply(peer, snapshot(other_origin, stamp(1, 9), entries(["b"])))

      assert Peer.origin(peer) == origin
    end

    # The origin follows the newest incarnation. The mark can stay on an older
    # incarnation until a snapshot of the newer one arrives.
    test "a diff of an old run that applies does not move the origin back", %{
      origin: origin,
      other_origin: other_origin
    } do
      peer = snapshot_peer(origin, 1, 3, ["a"])
      {peer, _changes} = Peer.apply(peer, diff(other_origin, stamp(2, 4), 3, [], []))
      assert Peer.origin(peer) == other_origin

      {peer, _changes} = Peer.apply(peer, diff(origin, stamp(1, 4), 3, entries(["b"]), []))

      assert refs(peer) == ["a", "b"]
      assert mark_tuple(peer) == {1, 4}
      assert Peer.origin(peer) == other_origin
    end

    test "a snapshot of an old run that is newer than the mark does not move the origin back", %{
      origin: origin,
      other_origin: other_origin
    } do
      peer = snapshot_peer(origin, 1, 3, ["a"])
      {peer, _changes} = Peer.apply(peer, diff(other_origin, stamp(2, 4), 3, [], []))

      {peer, _changes} = Peer.apply(peer, snapshot(origin, stamp(1, 5), entries(["b"])))

      assert refs(peer) == ["b"]
      assert mark_tuple(peer) == {1, 5}
      assert Peer.origin(peer) == other_origin
    end
  end

  describe "overtaking messages" do
    test "a goodbye of an old incarnation does not remove the entries of the new one",
         %{origin: origin, other_origin: other_origin} do
      peer = snapshot_peer(origin, 1, 2, ["a"])
      {peer, _changes} = Peer.apply(peer, snapshot(other_origin, stamp(2, 1), entries(["b"])))

      assert_unchanged(peer, snapshot(origin, stamp(1, 2), []))
      assert refs(peer) == ["b"]
    end

    test "a goodbye of the new incarnation removes the entries when the old one arrives later",
         %{origin: origin, other_origin: other_origin} do
      peer = snapshot_peer(origin, 1, 2, ["a"])
      {peer, _changes} = Peer.apply(peer, snapshot(other_origin, stamp(2, 1), []))

      assert_unchanged(peer, snapshot(origin, stamp(1, 2), []))
      assert refs(peer) == []
    end

    test "an older snapshot of one incarnation does not replace a newer one", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 4, ["b"])

      assert_unchanged(peer, snapshot(origin, stamp(1, 3), entries(["a"])))
      assert refs(peer) == ["b"]
    end
  end

  describe "tick/2" do
    test "keeps the peer until the silent count reaches the threshold", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      assert {:keep, peer} = Peer.tick(peer, 3)
      assert {:keep, peer} = Peer.tick(peer, 3)
      assert {:purge, _changes} = Peer.tick(peer, 3)
    end

    test "a threshold of 1 purges on the first tick", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])

      assert {:purge, _changes} = Peer.tick(peer, 1)
    end

    test "a snapshot resets the count", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])
      {:keep, peer} = tick_times(peer, 3, 2)
      {peer, _changes} = Peer.apply(peer, snapshot(origin, stamp(1, 4), entries(["a"])))

      assert {:keep, peer} = tick_times(peer, 3, 2)
      assert {:purge, _changes} = Peer.tick(peer, 3)
    end

    test "a stale message resets the count", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])
      {:keep, peer} = tick_times(peer, 3, 2)
      {peer, _changes} = Peer.apply(peer, snapshot(origin, stamp(1, 2), []))

      assert {:keep, peer} = tick_times(peer, 3, 2)
      assert {:purge, _changes} = Peer.tick(peer, 3)
    end

    test "a request resets the count", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])
      {:keep, peer} = tick_times(peer, 3, 2)
      {peer, _changes} = Peer.apply(peer, request(origin))

      assert {:keep, peer} = tick_times(peer, 3, 2)
      assert {:purge, _changes} = Peer.tick(peer, 3)
    end

    test "a stale diff resets the count", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])
      {:keep, peer} = tick_times(peer, 3, 2)
      {peer, _changes} = Peer.apply(peer, diff(origin, stamp(1, 2), 1, [], []))

      assert {:keep, peer} = tick_times(peer, 3, 2)
      assert {:purge, _changes} = Peer.tick(peer, 3)
    end

    test "a diff that sets behind resets the count", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a"])
      {:keep, peer} = tick_times(peer, 3, 2)
      {peer, _changes} = Peer.apply(peer, diff(origin, stamp(1, 6), 5, [], []))
      assert Peer.behind?(peer)

      assert {:keep, peer} = tick_times(peer, 3, 2)
      assert {:purge, _changes} = Peer.tick(peer, 3)
    end

    test "a purge returns every entry as a leave", %{origin: origin} do
      peer = snapshot_peer(origin, 1, 3, ["a", "b"])

      assert {:purge, changes} = Peer.tick(peer, 1)

      assert leaves(changes) == ["a", "b"]
      assert joins(changes) == []
    end

    test "a purge of an empty replica returns no changes", %{origin: origin} do
      {peer, _changes} = Peer.new(diff(origin, stamp(1, 4), 3, [], []))

      assert {:purge, changes} = Peer.tick(peer, 1)

      assert_no_changes(changes)
    end
  end

  defp entries(refs) do
    Enum.map(refs, &wire_entry("partition", &1, "key", %{}))
  end

  defp snapshot_peer(origin, incarnation, version, refs) do
    {peer, _changes} = Peer.new(snapshot(origin, stamp(incarnation, version), entries(refs)))
    peer
  end

  defp tick_times(peer, threshold, times) do
    Enum.reduce(1..times, {:keep, peer}, fn _, {:keep, peer} -> Peer.tick(peer, threshold) end)
  end

  defp assert_no_changes(changes) do
    assert joins(changes) == []
    assert leaves(changes) == []
  end

  defp observe(peer) do
    %{
      refs: refs(peer),
      behind: Peer.behind?(peer),
      mark: mark_tuple(peer),
      origin: Peer.origin(peer)
    }
  end

  defp assert_unchanged(peer, message) do
    {delivered, changes} = Peer.apply(peer, message)

    assert observe(delivered) == observe(peer)
    assert_no_changes(changes)
  end
end
