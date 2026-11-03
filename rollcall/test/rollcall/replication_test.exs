defmodule Rollcall.ReplicationTest do
  use Rollcall.Case, async: false

  import Rollcall.NetworkHelpers
  import Rollcall.PeerHelpers, only: [refs: 1, mark_tuple: 1]

  alias Rollcall.Transport.InMemory.Network

  # Two trackers for one scope run in one VM. Each has its own fake node and
  # sends its heartbeats through the in-memory network. The timers are off. A
  # test ticks the trackers and then reads the peer records.

  @node_a :a@host
  @node_b :b@host
  @threshold 3

  setup %{scope: scope} do
    network = start_network()
    a = start_node(scope, network, @node_a, silence_threshold: @threshold)
    b = start_node(scope, network, @node_b, silence_threshold: @threshold)
    {:ok, network: network, a: a, b: b}
  end

  describe "a heartbeat" do
    test "gives the other tracker a replica of the local entries", %{a: a, b: b} do
      ref = track(a, start_client(), "partition", "key")

      tick(a)
      sync(b)

      assert refs(peer(b, @node_a)) == [ref]
      assert mark_tuple(peer(b, @node_a)) == {tracker_state(a).incarnation, 1}
    end

    test "does not reach the tracker that sent it", %{a: a, b: b} do
      track(a, start_client(), "partition", "key")

      tick(a)
      sync(b)

      assert tracker_state(a).peers == %{}
    end

    test "gives each tracker the entries of the other", %{a: a, b: b} do
      ref_a = track(a, start_client(), "partition", "key_a")
      ref_b = track(b, start_client(), "partition", "key_b")

      tick(a)
      tick(b)
      sync(a)
      sync(b)

      assert refs(peer(b, @node_a)) == [ref_a]
      assert refs(peer(a, @node_b)) == [ref_b]
    end

    test "removes an untracked entry from the replica", %{a: a, b: b} do
      client = start_client()
      track(a, client, "partition", "key")
      tick(a)
      untrack(a, client, "partition", "key")

      tick(a)
      sync(b)

      assert refs(peer(b, @node_a)) == []
    end

    test "creates a record for an empty tracker", %{a: a, b: b} do
      tick(a)
      sync(b)

      assert refs(peer(b, @node_a)) == []
    end
  end

  describe "a lost heartbeat" do
    test "is repaired by the next heartbeat", %{network: network, a: a, b: b} do
      client = start_client()
      ref_1 = track(a, client, "partition", "key_1")
      tick(a)

      ref_2 = track(a, client, "partition", "key_2")
      :ok = Network.drop_next(network)
      tick(a)
      sync(b)
      assert refs(peer(b, @node_a)) == [ref_1]

      tick(a)
      sync(b)
      assert refs(peer(b, @node_a)) == Enum.sort([ref_1, ref_2])
    end
  end

  describe "a goodbye" do
    test "empties the replica at once", %{scope: scope, a: a, b: b} do
      track(a, start_client(), "partition", "key")
      tick(a)
      sync(b)
      assert [_] = refs(peer(b, @node_a))

      stop_node({scope, @node_a})
      sync(b)

      assert refs(peer(b, @node_a)) == []
    end
  end

  describe "a crash" do
    test "keeps the replica until the silence threshold", %{a: a, b: b} do
      ref = track(a, start_client(), "partition", "key")
      tick(a)
      sync(b)
      kill_node(a)

      tick(b, @threshold - 1)
      assert refs(peer(b, @node_a)) == [ref]

      tick(b)
      assert peer(b, @node_a) == nil
    end

    test "is replaced by the first heartbeat of the new tracker", %{scope: scope, network: network, a: a, b: b} do
      track(a, start_client(), "partition", "old_key")
      tick(a)
      sync(b)
      kill_node(a)

      a2 = start_node(scope, network, @node_a, id: :restarted, silence_threshold: @threshold)
      ref = track(a2, start_client(), "partition", "new_key")
      tick(a2)
      sync(b)

      assert refs(peer(b, @node_a)) == [ref]
      assert mark_tuple(peer(b, @node_a)) == {tracker_state(a2).incarnation, 1}
    end
  end
end
