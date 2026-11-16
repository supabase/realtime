defmodule Rollcall.RefsReadTest do
  use Rollcall.Case, async: true

  import Rollcall.TrackerHelpers
  import Rollcall.Tracker.Messages, only: [snapshot: 3, stamp: 2, wire_entry: 4]

  alias Rollcall.Tracker
  alias Rollcall.Tracker.View

  @node_a :a@host
  @threshold 3

  setup %{scope: scope, rollcall: rollcall} do
    tracker = start_tracker(rollcall, scope, @threshold)
    {:ok, local_1} = Rollcall.track(rollcall, self(), scope, "p1", "k1", %{n: 1})
    {:ok, local_2} = Rollcall.track(rollcall, self(), scope, "p2", "k2", %{n: 2})

    deliver(
      tracker,
      scope,
      snapshot(remote_pid(@node_a, 1), stamp(1, 1), [
        wire_entry("p1", "k3", "peer-1", %{n: 3}),
        wire_entry("p3", "k4", "peer-3", %{n: 4})
      ])
    )

    {:ok, local_1: local_1, local_2: local_2}
  end

  describe "refs/2" do
    test "returns the refs of every partition, local and peer", %{
      scope: scope,
      rollcall: rollcall,
      local_1: local_1,
      local_2: local_2
    } do
      refs = Rollcall.refs(rollcall, scope)

      assert Map.keys(refs) |> Enum.sort() == ["p1", "p2", "p3"]
      assert Enum.sort(refs["p1"]) == Enum.sort([local_1, "peer-1"])
      assert refs["p2"] == [local_2]
      assert refs["p3"] == ["peer-3"]
    end
  end

  describe "refs/3" do
    test "returns the refs of one partition only", %{scope: scope, rollcall: rollcall, local_1: local_1} do
      assert Enum.sort(Rollcall.refs(rollcall, scope, "p1")) == Enum.sort([local_1, "peer-1"])
      assert Rollcall.refs(rollcall, scope, "p3") == ["peer-3"]
      assert Rollcall.refs(rollcall, scope, "no-such-partition") == []
    end
  end

  describe "a read" do
    test "returns an empty list and starts no tracker when no tracker runs", %{rollcall: rollcall} do
      scope = unique_scope()

      assert Rollcall.refs(rollcall, scope) == %{}
      assert Rollcall.refs(rollcall, scope, "p1") == []
      assert Tracker.whereis(rollcall, scope) == nil
    end

    # A tracker can stop between the registry lookup and the read, and its table goes with it.
    test "returns an empty result when the table is gone" do
      table = View.new()
      :ets.delete(table)

      assert View.refs(table) == %{}
      assert View.refs(table, "p1") == []
    end
  end

  # A call returns after the tracker handled every earlier message.
  defp deliver(tracker, scope, message) do
    send(tracker, {:deliver, scope, message})
    :sys.get_state(tracker)
    :ok
  end
end
