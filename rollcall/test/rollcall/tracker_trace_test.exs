defmodule Rollcall.TrackerTraceTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Rollcall.TraceHelpers

  # Each track and each untrack emits one event. The event holds the refs of the
  # joins and the leaves of the change, and the version after the change.

  describe "track" do
    test "emits an event with the new entry as a join", %{scope: scope} do
      pid = self()

      check_trace(
        fn ->
          {:ok, ref} = Rollcall.track(pid, scope, "partition", "key", %{})
          ref
        end,
        fn ref, trace ->
          assert [event] = events(trace, :rollcall_tracker_track, scope)

          assert %{
                   pid: ^pid,
                   partition: "partition",
                   key: "key",
                   joins: [^ref],
                   leaves: [],
                   version: 1
                 } = event
        end
      )
    end

    test "emits an event with the old entry as a leave when the key is tracked again", %{
      scope: scope
    } do
      check_trace(
        fn ->
          {:ok, ref_1} = Rollcall.track(self(), scope, "partition", "key", %{a: 1})
          {:ok, ref_2} = Rollcall.track(self(), scope, "partition", "key", %{a: 2})
          {ref_1, ref_2}
        end,
        fn {ref_1, ref_2}, trace ->
          assert [_first, second] = events(trace, :rollcall_tracker_track, scope)
          assert %{joins: [^ref_2], leaves: [^ref_1], version: 2} = second
        end
      )
    end

    test "emits an event with a leave when the meta is the same", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, ref_1} = Rollcall.track(self(), scope, "partition", "key", %{a: 1})
          {:ok, ref_2} = Rollcall.track(self(), scope, "partition", "key", %{a: 1})
          {ref_1, ref_2}
        end,
        fn {ref_1, ref_2}, trace ->
          assert [_first, second] = events(trace, :rollcall_tracker_track, scope)
          assert %{joins: [^ref_2], leaves: [^ref_1]} = second
        end
      )
    end

    test "emits one event for each track, in order", %{scope: scope} do
      check_trace(
        fn ->
          for n <- 1..3 do
            {:ok, ref} = Rollcall.track(self(), scope, "partition", "key_#{n}", %{})
            ref
          end
        end,
        fn refs, trace ->
          events = events(trace, :rollcall_tracker_track, scope)

          assert Enum.map(events, & &1.version) == [1, 2, 3]
          assert Enum.flat_map(events, & &1.joins) == refs
        end
      )
    end
  end

  describe "untrack" do
    test "emits an event with the removed entry as a leave", %{scope: scope} do
      pid = self()

      check_trace(
        fn ->
          {:ok, ref} = Rollcall.track(pid, scope, "partition", "key", %{})
          :ok = Rollcall.untrack(pid, scope, "partition", "key")
          ref
        end,
        fn ref, trace ->
          assert [event] = events(trace, :rollcall_tracker_untrack, scope)

          assert %{
                   pid: ^pid,
                   partition: "partition",
                   key: "key",
                   joins: [],
                   leaves: [^ref],
                   version: 2
                 } = event
        end
      )
    end

    test "emits an event with no leave and an unchanged version when no entry matches", %{
      scope: scope
    } do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
          :ok = Rollcall.untrack(self(), scope, "partition", "other_key")
        end,
        fn _result, trace ->
          assert [%{joins: [], leaves: [], version: 1}] =
                   events(trace, :rollcall_tracker_untrack, scope)
        end
      )
    end

    test "emits its event after the event of the track", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
          :ok = Rollcall.untrack(self(), scope, "partition", "key")
        end,
        fn _result, trace ->
          kinds = [:rollcall_tracker_track, :rollcall_tracker_untrack]

          assert [%{"$kind": :rollcall_tracker_track}, %{"$kind": :rollcall_tracker_untrack}] =
                   events(trace, kinds, scope)
        end
      )
    end

    test "emits no event when no tracker runs", %{scope: scope} do
      check_trace(
        fn -> :ok = Rollcall.untrack(self(), scope, "partition", "key") end,
        fn _result, trace ->
          assert [] = events(trace, :rollcall_tracker_untrack, scope)
        end
      )
    end
  end
end
