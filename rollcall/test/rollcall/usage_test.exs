defmodule Rollcall.UsageTest do
  use Rollcall.Case, async: true

  import Rollcall.TrackerHelpers, only: [remote_pid: 2]
  import Rollcall.Tracker.Messages, only: [snapshot: 3, stamp: 2, wire_entry: 4]

  alias Rollcall.Tracker
  alias Rollcall.Transport.PassThrough

  # `usage/2` reads the views of the trackers of an instance. The result has the number of scopes
  # with entries, the number of partitions with entries, and the number of partitions in each bucket.
  # The caller passes the bounds. The map `entry_count_buckets` has one key for each bound, and the
  # key `:infinity` for the partitions above the last bound.
  #
  # The tests use the bounds 2 and 4, so the keys are 2, 4 and `:infinity`. The tests start their
  # own instance for the transport: `Rollcall.Transport.PassThrough`. The timer is off. A test
  # delivers each message and sends each tick.

  @buckets [2, 4]
  @node_a :a@host
  @threshold 3

  setup do
    name = unique_name()

    start_supervised!(
      {Rollcall,
       name: name, silence_threshold: @threshold, heartbeat_period_in_ms: :manual, transport: {PassThrough, []}}
    )

    %{usage_rollcall: name}
  end

  test "reports zero scopes, zero partitions and every bucket at zero when no tracker runs", %{
    usage_rollcall: rollcall
  } do
    assert Rollcall.usage(rollcall, @buckets) == usage(0, 0, %{2 => 0, 4 => 0, :infinity => 0})
  end

  test "does not count a tracker that holds no entry as a scope", %{usage_rollcall: rollcall, scope: scope} do
    :ok = Rollcall.ensure_started(rollcall, scope)

    assert Rollcall.usage(rollcall, @buckets) == usage(0, 0, %{2 => 0, 4 => 0, :infinity => 0})
  end

  describe "the buckets" do
    test "put a partition in the first bucket whose bound is at or above its count", %{
      usage_rollcall: rollcall,
      scope: scope
    } do
      track(rollcall, scope, "two", 2)
      track(rollcall, scope, "three", 3)
      track(rollcall, scope, "five", 5)

      assert Rollcall.usage(rollcall, @buckets) == usage(1, 3, %{2 => 1, 4 => 1, :infinity => 1})
    end

    test "move a partition down when an untrack lowers its count, and drop it at zero", %{
      usage_rollcall: rollcall,
      scope: scope
    } do
      track(rollcall, scope, "room", 3)
      assert Rollcall.usage(rollcall, @buckets) == usage(1, 1, %{2 => 0, 4 => 1, :infinity => 0})

      :ok = Rollcall.untrack(rollcall, self(), scope, "room", "key-1")
      assert Rollcall.usage(rollcall, @buckets) == usage(1, 1, %{2 => 1, 4 => 0, :infinity => 0})

      :ok = Rollcall.untrack(rollcall, self(), scope, "room", "key-2")
      :ok = Rollcall.untrack(rollcall, self(), scope, "room", "key-3")
      assert Rollcall.usage(rollcall, @buckets) == usage(0, 0, %{2 => 0, 4 => 0, :infinity => 0})
    end
  end

  test "counts a track of the same key again as one entry", %{usage_rollcall: rollcall, scope: scope} do
    for _ <- 1..3, do: {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "room", "key", %{})

    assert Rollcall.usage(rollcall, @buckets) == usage(1, 1, %{2 => 1, 4 => 0, :infinity => 0})
  end

  test "drops the entries of a process that exits", %{usage_rollcall: rollcall, scope: scope} do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    {:ok, _ref} = Rollcall.track(rollcall, pid, scope, "room", "key", %{})
    assert Rollcall.usage(rollcall, @buckets) == usage(1, 1, %{2 => 1, 4 => 0, :infinity => 0})

    Process.exit(pid, :kill)

    eventually(fn -> assert Rollcall.usage(rollcall, @buckets) == usage(0, 0, %{2 => 0, 4 => 0, :infinity => 0}) end)
  end

  describe "the entries of a peer" do
    test "add to the count of a partition with local entries", %{usage_rollcall: rollcall, scope: scope} do
      track(rollcall, scope, "room", 1)
      tracker = Tracker.whereis(rollcall, scope)

      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), peer_entries("room", ["a", "b"])))

      assert Rollcall.usage(rollcall, @buckets) == usage(1, 1, %{2 => 0, 4 => 1, :infinity => 0})
    end

    test "leave when a later snapshot drops them", %{usage_rollcall: rollcall, scope: scope} do
      :ok = Rollcall.ensure_started(rollcall, scope)
      tracker = Tracker.whereis(rollcall, scope)
      origin = remote_pid(@node_a, 1)

      deliver(tracker, scope, snapshot(origin, stamp(1, 1), peer_entries("room", ["a", "b", "c"])))
      assert Rollcall.usage(rollcall, @buckets) == usage(1, 1, %{2 => 0, 4 => 1, :infinity => 0})

      deliver(tracker, scope, snapshot(origin, stamp(1, 2), peer_entries("room", ["a"])))
      assert Rollcall.usage(rollcall, @buckets) == usage(1, 1, %{2 => 1, 4 => 0, :infinity => 0})
    end

    test "leave when the tick purges the silent peer", %{usage_rollcall: rollcall, scope: scope} do
      :ok = Rollcall.ensure_started(rollcall, scope)
      tracker = Tracker.whereis(rollcall, scope)

      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), peer_entries("room", ["a", "b"])))
      assert Rollcall.usage(rollcall, @buckets) == usage(1, 1, %{2 => 1, 4 => 0, :infinity => 0})

      tick(tracker, @threshold)

      assert Rollcall.usage(rollcall, @buckets) == usage(0, 0, %{2 => 0, 4 => 0, :infinity => 0})
    end
  end

  test "sums the counters of the trackers", %{usage_rollcall: rollcall, scope: scope} do
    track(rollcall, scope, "room", 1)
    track(rollcall, scope <> "-b", "room", 3)
    track(rollcall, scope <> "-b", "other", 1)

    assert Rollcall.usage(rollcall, @buckets) == usage(2, 3, %{2 => 2, 4 => 1, :infinity => 0})
  end

  test "does not count a tracker that stopped", %{usage_rollcall: rollcall, scope: scope} do
    track(rollcall, scope, "room", 1)
    track(rollcall, scope <> "-b", "room", 1)

    :ok = GenServer.stop(Tracker.whereis(rollcall, scope))

    assert Rollcall.usage(rollcall, @buckets) == usage(1, 1, %{2 => 1, 4 => 0, :infinity => 0})
  end

  test "uses the bounds that the caller passes", %{usage_rollcall: rollcall, scope: scope} do
    track(rollcall, scope, "room", 3)

    assert Rollcall.usage(rollcall, [2, 4]) == usage(1, 1, %{2 => 0, 4 => 1, :infinity => 0})
    assert Rollcall.usage(rollcall, [5]) == usage(1, 1, %{5 => 1, :infinity => 0})
    assert Rollcall.usage(rollcall, []) == usage(1, 1, %{:infinity => 1})
  end

  defp usage(scope_count, partition_count, entry_count_buckets) do
    %{scope_count: scope_count, partition_count: partition_count, entry_count_buckets: entry_count_buckets}
  end

  # Tracks `count` entries of the test process in `partition`. The keys are unique in a partition.
  defp track(rollcall, scope, partition, count) do
    for n <- 1..count do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, partition, "key-#{n}", %{})
    end

    :ok
  end

  defp peer_entries(partition, refs), do: Enum.map(refs, &wire_entry(partition, "key-#{&1}", &1, %{}))

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

  # Runs `assertion` until it passes. The tracker handles an exit of a tracked process in its own
  # time, and the test has no message to wait for.
  defp eventually(assertion, attempts \\ 100) do
    assertion.()
  rescue
    error in ExUnit.AssertionError ->
      if attempts == 0, do: reraise(error, __STACKTRACE__)
      Process.sleep(10)
      eventually(assertion, attempts - 1)
  end
end
