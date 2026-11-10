defmodule Rollcall.EnsureStartedTest do
  use Rollcall.Case, async: true

  import Rollcall.Tracker.Messages, only: [snapshot: 3, stamp: 2, wire_entry: 4]
  import Rollcall.TraceHelpers, only: [expire_grace: 1]
  import Rollcall.TrackerHelpers, only: [remote_pid: 2]

  alias Rollcall.Tracker
  alias Rollcall.Transport.FailInit
  alias Rollcall.Transport.Active

  # `ensure_started/2` starts the tracker of a scope when none runs. A node that
  # has listeners and has never tracked calls it, so the node holds the state of
  # its peers.

  describe "ensure_started/2" do
    test "starts a tracker when none runs", %{scope: scope, rollcall: rollcall} do
      assert Tracker.whereis(rollcall, scope) == nil

      assert :ok = Rollcall.ensure_started(rollcall, scope)

      assert is_pid(Tracker.whereis(rollcall, scope))
    end

    test "keeps the tracker that runs", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
      tracker = Tracker.whereis(rollcall, scope)

      assert :ok = Rollcall.ensure_started(rollcall, scope)

      assert Tracker.whereis(rollcall, scope) == tracker
    end

    test "uses one tracker for concurrent calls", %{scope: scope, rollcall: rollcall} do
      trackers =
        1..50
        |> Task.async_stream(fn _ ->
          :ok = Rollcall.ensure_started(rollcall, scope)
          Tracker.whereis(rollcall, scope)
        end)
        |> Enum.map(fn {:ok, tracker} -> tracker end)

      assert [tracker] = Enum.uniq(trackers)
      assert is_pid(tracker)
    end

    test "returns the error when init/2 of the transport fails", %{scope: scope} do
      counter = :atomics.new(1, [])
      :atomics.put(counter, 1, 1)
      rollcall = unique_name()
      start_supervised!({Rollcall, name: rollcall, transport: {FailInit, failures: counter}})

      assert {:error, {%RuntimeError{message: "transport init failed"}, _stacktrace}} =
               Rollcall.ensure_started(rollcall, scope)

      assert Tracker.whereis(rollcall, scope) == nil
    end
  end

  describe "a tracker that ensure_started/2 starts" do
    setup do
      active = start_supervised!({Agent, fn -> true end})
      rollcall = unique_name()

      start_supervised!(
        {Rollcall, name: rollcall, heartbeat_period_in_ms: :manual, transport: {Active, active: active}}
      )

      {:ok, active: active, rollcall: rollcall}
    end

    # A node with listeners that never tracked locally.
    test "keeps the entries of a peer at the end of the grace period while the transport is active", ctx do
      %{scope: scope, rollcall: rollcall} = ctx
      :ok = Rollcall.ensure_started(rollcall, scope)
      tracker = Tracker.whereis(rollcall, scope)
      origin = remote_pid(:peer@host, 1)
      send(tracker, {:deliver, scope, snapshot(origin, stamp(1, 1), [wire_entry("partition", "key", "ref", %{n: 1})])})

      expire_grace(tracker)
      _ = :sys.get_state(tracker)

      assert [{"ref", "key", %{n: 1}}] = Rollcall.state(rollcall, scope, "partition")
    end

    test "stops at the end of the grace period when the transport is not active", ctx do
      %{scope: scope, rollcall: rollcall, active: active} = ctx
      Agent.update(active, fn _ -> false end)
      :ok = Rollcall.ensure_started(rollcall, scope)
      tracker = Tracker.whereis(rollcall, scope)
      monitor = Process.monitor(tracker)

      expire_grace(tracker)

      assert_receive {:DOWN, ^monitor, :process, ^tracker, :normal}
    end
  end
end
