defmodule Rollcall.TelemetryUsageTest do
  use Rollcall.Case, async: true

  import Rollcall.NetworkHelpers, only: [start_client: 0, track: 4, tick: 1]
  import Rollcall.TrackerHelpers
  import Rollcall.Tracker.Messages, only: [snapshot: 3, stamp: 2, wire_entry: 4]

  # The tracker emits a usage event at the end of each tick. A test listens for the events of its
  # own scope, so the tests can run at the same time.
  #
  # The tracker uses `Rollcall.Transport.PassThrough`. A test delivers a message with
  # `send(tracker, {:deliver, scope, message})`, and sends each `:tick` itself.

  @usage Rollcall.Metrics.tracker_usage()

  @node_a :a@host
  @threshold 3

  setup %{scope: scope} do
    id = {__MODULE__, make_ref()}

    :telemetry.attach(id, @usage, &__MODULE__.handle_event/4, %{pid: self(), scope: scope})

    on_exit(fn -> :telemetry.detach(id) end)
  end

  def handle_event(event, measurements, %{scope: scope} = metadata, %{pid: pid, scope: scope}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  test "is emitted at each tick with the scope and four integer measurements", %{scope: scope, rollcall: rollcall} do
    tracker = start_tracker(rollcall, scope, @threshold)

    tick(tracker)

    assert_receive {:telemetry, @usage, %{entries: 0, process_bytes: process, ets_bytes: ets, reductions: reductions},
                    %{scope: ^scope} = metadata}

    assert Map.keys(metadata) == [:scope]
    assert is_integer(process) and process > 0, "process_bytes must be a positive integer, got: #{inspect(process)}"
    assert is_integer(ets) and ets > 0, "ets_bytes must be a positive integer, got: #{inspect(ets)}"

    assert is_integer(reductions) and reductions > 0,
           "reductions must be a positive integer, got: #{inspect(reductions)}"
  end

  test "is not emitted between ticks", %{scope: scope, rollcall: rollcall} do
    tracker = start_tracker(rollcall, scope, @threshold)
    client = start_client()

    track(tracker, client, "partition", "key_1")
    deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(1..3)))

    refute_received {:telemetry, @usage, _, _}
  end

  describe "entries" do
    test "counts the local entries and the entries of the peers", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)
      client = start_client()
      track(tracker, client, "partition", "key_1")
      track(tracker, client, "partition", "key_2")
      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(1..3)))

      tick(tracker)

      assert_receive {:telemetry, @usage, %{entries: 5}, %{scope: ^scope}}
    end

    test "counts the entries that remain after the tick purged a peer", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)
      client = start_client()
      track(tracker, client, "partition", "key_1")
      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(1..3)))

      tick(tracker)
      tick(tracker)
      tick(tracker)

      assert_receive {:telemetry, @usage, %{entries: 4}, %{scope: ^scope}}
      assert_receive {:telemetry, @usage, %{entries: 4}, %{scope: ^scope}}
      assert_receive {:telemetry, @usage, %{entries: 1}, %{scope: ^scope}}
    end
  end

  describe "ets_bytes" do
    test "is the memory of the view table in bytes", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)
      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(1..200)))

      tick(tracker)

      [{^tracker, view}] = Registry.lookup(rollcall, scope)
      expected = :ets.info(view, :memory) * :erlang.system_info(:wordsize)
      assert_receive {:telemetry, @usage, %{ets_bytes: ^expected}, %{scope: ^scope}}
    end
  end

  describe "reductions" do
    test "counts the reductions since the previous tick, not since the start", %{scope: scope, rollcall: rollcall} do
      tracker = start_tracker(rollcall, scope, @threshold)
      deliver(tracker, scope, snapshot(remote_pid(@node_a, 1), stamp(1, 1), entries(1..2_000)))

      tick(tracker)
      tick(tracker)

      assert_receive {:telemetry, @usage, %{reductions: busy}, %{scope: ^scope}}
      assert_receive {:telemetry, @usage, %{reductions: quiet}, %{scope: ^scope}}
      # The first tick follows the work for 2000 entries. The second tick has no work to count, apart
      # from the tick itself. A total since the start would make `quiet` larger than `busy`.
      assert quiet > 0
      assert quiet < busy
    end
  end

  defp entries(range), do: Enum.map(range, &wire_entry("partition", "key", "ref_#{&1}", %{}))

  defp deliver(tracker, scope, message) do
    send(tracker, {:deliver, scope, message})
    :sys.get_state(tracker)
    :ok
  end
end
