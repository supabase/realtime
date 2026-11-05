defmodule Rollcall.StateReadTest do
  use Rollcall.Case, async: true

  import Rollcall.TrackerHelpers
  import Rollcall.Tracker.Messages, only: [diff: 5, snapshot: 3, stamp: 2, wire_entry: 4]

  alias Rollcall.Tracker

  @node_a :a@host
  @threshold 3

  describe "the view of local entries" do
    test "holds the entries that processes track", %{scope: scope, rollcall: rollcall} do
      {:ok, ref_1} = Rollcall.track(rollcall, self(), scope, "p1", "k1", %{n: 1})
      {:ok, ref_2} = Rollcall.track(rollcall, self(), scope, "p2", "k2", %{n: 2})

      assert Rollcall.state(rollcall, scope, "p1") == [{ref_1, "k1", %{n: 1}}]
      assert Rollcall.state(rollcall, scope, "p2") == [{ref_2, "k2", %{n: 2}}]

      assert Enum.sort(Rollcall.state(rollcall, scope)) ==
               Enum.sort([{"p1", ref_1, "k1", %{n: 1}}, {"p2", ref_2, "k2", %{n: 2}}])
    end

    test "loses an entry when the process untracks it", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "p1", "k1", %{})
      {:ok, ref_2} = Rollcall.track(rollcall, self(), scope, "p1", "k2", %{})

      :ok = Rollcall.untrack(rollcall, self(), scope, "p1", "k1")

      assert Rollcall.state(rollcall, scope, "p1") == [{ref_2, "k2", %{}}]
    end

    test "replaces an entry when the process tracks the same key again", %{scope: scope, rollcall: rollcall} do
      {:ok, old_ref} = Rollcall.track(rollcall, self(), scope, "p1", "key", %{n: 1})
      {:ok, new_ref} = Rollcall.track(rollcall, self(), scope, "p1", "key", %{n: 2})

      assert Rollcall.state(rollcall, scope, "p1") == [{new_ref, "key", %{n: 2, rc_prev_ref: old_ref}}]
    end

    test "loses the entries of a process that exits", %{scope: scope, rollcall: rollcall} do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, _ref} = Rollcall.track(rollcall, pid, scope, "p1", "key", %{})
      {:ok, ref} = Rollcall.track(rollcall, self(), scope, "p1", "other", %{})

      Process.exit(pid, :kill)

      eventually(fn -> assert Rollcall.state(rollcall, scope, "p1") == [{ref, "other", %{}}] end)
    end
  end

  describe "the view of peer entries" do
    test "holds the entries of a snapshot, and a later snapshot replaces them", %{scope: scope, rollcall: rollcall} do
      origin = remote_pid(@node_a, 1)
      tracker = start_tracker(rollcall, scope, @threshold)

      deliver(
        tracker,
        scope,
        snapshot(origin, stamp(1, 1), [wire_entry("p1", "k1", "a", %{n: 1}), wire_entry("p2", "k2", "b", %{})])
      )

      assert Rollcall.state(rollcall, scope, "p1") == [{"a", "k1", %{n: 1}}]

      assert Enum.sort(Rollcall.state(rollcall, scope)) ==
               [{"p1", "a", "k1", %{n: 1}}, {"p2", "b", "k2", %{}}]

      deliver(tracker, scope, snapshot(origin, stamp(1, 2), [wire_entry("p1", "k1", "c", %{n: 2})]))

      assert Rollcall.state(rollcall, scope) == [{"p1", "c", "k1", %{n: 2}}]
    end

    test "applies the joins and the leaves of a diff", %{scope: scope, rollcall: rollcall} do
      origin = remote_pid(@node_a, 1)
      tracker = start_tracker(rollcall, scope, @threshold)
      deliver(tracker, scope, snapshot(origin, stamp(1, 1), [wire_entry("p1", "k1", "a", %{})]))

      deliver(tracker, scope, diff(origin, stamp(1, 2), 1, [wire_entry("p1", "k2", "b", %{})], ["a"]))

      assert Rollcall.state(rollcall, scope, "p1") == [{"b", "k2", %{}}]
    end

    test "loses the entries of a silent peer and keeps the local entries", %{scope: scope, rollcall: rollcall} do
      origin = remote_pid(@node_a, 1)
      tracker = start_tracker(rollcall, scope, @threshold)
      {:ok, local_ref} = Rollcall.track(rollcall, self(), scope, "p1", "local", %{})
      deliver(tracker, scope, snapshot(origin, stamp(1, 1), [wire_entry("p1", "remote", "a", %{})]))
      assert length(Rollcall.state(rollcall, scope, "p1")) == 2

      tick(tracker, @threshold)

      assert Rollcall.state(rollcall, scope, "p1") == [{local_ref, "local", %{}}]
    end
  end

  describe "a read" do
    test "does not wait for the tracker", %{scope: scope, rollcall: rollcall} do
      {:ok, ref} = Rollcall.track(rollcall, self(), scope, "p1", "key", %{})
      tracker = Tracker.whereis(rollcall, scope)

      :ok = :sys.suspend(tracker)

      try do
        assert Rollcall.state(rollcall, scope, "p1") == [{ref, "key", %{}}]
        assert Rollcall.state(rollcall, scope) == [{"p1", ref, "key", %{}}]
      after
        :ok = :sys.resume(tracker)
      end
    end

    test "returns an empty list and starts no tracker when no tracker runs", %{scope: scope, rollcall: rollcall} do
      assert Rollcall.state(rollcall, scope, "p1") == []
      assert Rollcall.state(rollcall, scope) == []
      assert Tracker.whereis(rollcall, scope) == nil
    end

    test "returns an empty list when the instance does not run", %{scope: scope} do
      assert Rollcall.state(unique_name(), scope, "p1") == []
      assert Rollcall.state(unique_name(), scope) == []
    end
  end

  describe "the table of the view" do
    test "belongs to the tracker and is gone when the tracker stops", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "p1", "key", %{})
      [{tracker, table}] = Registry.lookup(rollcall, scope)
      assert :ets.info(table, :owner) == tracker

      monitor = Process.monitor(tracker)
      Process.exit(tracker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^tracker, :killed}

      assert :ets.info(table) == :undefined
      assert Rollcall.state(rollcall, scope, "p1") == []
      assert Rollcall.state(rollcall, scope) == []
    end
  end

  defp deliver(tracker, scope, message) do
    send(tracker, {:deliver, scope, message})
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

  # Runs `assertion` until it passes. The tracker handles an exit of a tracked
  # process in its own time, and the test has no message to wait for.
  defp eventually(assertion, attempts \\ 100) do
    assertion.()
  rescue
    error in ExUnit.AssertionError ->
      if attempts == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end
end
