defmodule Rollcall.LifecycleTraceTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Rollcall.TraceHelpers

  alias Rollcall.Tracker
  alias Rollcall.Tracker.Local

  # The tests do not wait for the grace period. They wait for the trace point
  # that marks the start of the timer. Then they send the timeout message with
  # `expire_grace/1`, or they check the timer with `:erlang.read_timer/1`.

  describe "stop" do
    test "stops the tracker when the grace period ends", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
          tracker = Tracker.whereis(scope)
          monitor = Process.monitor(tracker)

          wait_for_event %{"$kind": :rollcall_tracker_empty, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key")
          end

          wait_for_event %{"$kind": :rollcall_tracker_stopped, scope: ^scope} do
            expire_grace(tracker)
          end

          assert_receive {:DOWN, ^monitor, :process, ^tracker, :normal}
          refute scope in Rollcall.scopes()
        end,
        fn trace ->
          assert [%{"$kind": :rollcall_tracker_empty}, %{"$kind": :rollcall_tracker_stopped}] =
                   events(trace, [:rollcall_tracker_empty, :rollcall_tracker_stopped], scope)
        end
      )
    end

    test "keeps the tracker while an entry remains", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})
          tracker = Tracker.whereis(scope)

          :ok = Rollcall.untrack(self(), scope, "partition", "key_1")
          tp(:test_first_untrack_done, %{scope: scope})

          wait_for_event %{"$kind": :rollcall_tracker_empty, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key_2")
          end

          wait_for_event %{"$kind": :rollcall_tracker_stopped, scope: ^scope} do
            expire_grace(tracker)
          end
        end,
        fn trace ->
          kinds = [
            :test_first_untrack_done,
            :rollcall_tracker_empty,
            :rollcall_tracker_stopped
          ]

          assert [
                   %{"$kind": :test_first_untrack_done},
                   %{"$kind": :rollcall_tracker_empty},
                   %{"$kind": :rollcall_tracker_stopped}
                 ] = events(trace, kinds, scope)
        end
      )
    end

    test "starts a new tracker with a greater incarnation for a track after the stop", %{
      scope: scope
    } do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})
          old_tracker = Tracker.whereis(scope)
          old_incarnation = Tracker.get_state(scope).incarnation
          monitor = Process.monitor(old_tracker)

          :ok = Rollcall.untrack(self(), scope, "partition", "key_1")

          wait_for_event %{"$kind": :rollcall_tracker_empty, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key_2")
          end

          wait_for_event %{"$kind": :rollcall_tracker_stopped, scope: ^scope} do
            expire_grace(old_tracker)
          end

          assert_receive {:DOWN, ^monitor, :process, ^old_tracker, :normal}

          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})

          new_tracker = Tracker.whereis(scope)
          state = Tracker.get_state(scope)

          assert is_pid(new_tracker)
          refute new_tracker == old_tracker
          assert state.incarnation > old_incarnation
          assert state.version == 1
        end,
        fn trace ->
          assert [_, _] = events(trace, :rollcall_tracker_started, scope)
        end
      )
    end
  end

  describe "grace period" do
    test "keeps the empty tracker running", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
          tracker = Tracker.whereis(scope)

          wait_for_event %{"$kind": :rollcall_tracker_empty, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key")
          end

          assert Process.alive?(tracker)
          assert Tracker.whereis(scope) == tracker
          assert scope in Rollcall.scopes()
        end,
        fn trace ->
          assert [] = events(trace, :rollcall_tracker_stopped, scope)
        end
      )
    end

    test "starts when the last process exits", %{scope: scope} do
      check_trace(
        fn ->
          pid = start_process()
          {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key", %{})
          tracker = Tracker.whereis(scope)

          wait_for_event %{"$kind": :rollcall_tracker_empty, scope: ^scope} do
            Process.exit(pid, :kill)
          end

          assert Process.alive?(tracker)
        end,
        fn trace ->
          assert [] = events(trace, :rollcall_tracker_stopped, scope)
        end
      )
    end

    test "starts a timer with the length of the grace period", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
          tracker = Tracker.whereis(scope)

          wait_for_event %{"$kind": :rollcall_tracker_empty, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key")
          end

          # The default grace period is 5000 ms.
          remaining = :erlang.read_timer(empty_timer(tracker))

          assert is_integer(remaining)
          assert remaining > 0
          assert remaining <= 5_000
        end,
        fn _trace -> :ok end
      )
    end

    test "cancels the timer when a track arrives", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
          tracker = Tracker.whereis(scope)

          wait_for_event %{"$kind": :rollcall_tracker_empty, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key_1")
          end

          timer = empty_timer(tracker)

          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})

          # `read_timer/1` returns false for a timer that is cancelled.
          assert :erlang.read_timer(timer) == false
          assert Tracker.whereis(scope) == tracker
        end,
        fn trace ->
          assert [] = events(trace, :rollcall_tracker_stopped, scope)
          assert [_] = events(trace, :rollcall_tracker_started, scope)
        end
      )
    end

    test "ignores the timeout message of a cancelled timer", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
          tracker = Tracker.whereis(scope)

          wait_for_event %{"$kind": :rollcall_tracker_empty, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key_1")
          end

          timer = empty_timer(tracker)
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})

          # The timer fired before the track cancelled it, so its message is in the mailbox.
          send(tracker, {:timeout, timer, :empty_timeout})

          # The tracker handles a call after the message that came before it.
          assert %{scope: ^scope} = Tracker.get_state(scope)
          assert Process.alive?(tracker)
          assert Tracker.whereis(scope) == tracker
        end,
        fn trace ->
          assert [] = events(trace, :rollcall_tracker_stopped, scope)
        end
      )
    end
  end

  describe "monitors" do
    test "monitors a pid that tracks an entry", %{scope: scope} do
      pid = start_process()
      {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key", %{})

      assert monitor_count(Tracker.whereis(scope), pid) == 1
    end

    test "monitors a pid once for several entries", %{scope: scope} do
      pid = start_process()
      {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key_1", %{})
      {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key_2", %{})
      {:ok, _ref} = Rollcall.track(pid, scope, "other_partition", "key_1", %{})

      assert monitor_count(Tracker.whereis(scope), pid) == 1
    end

    test "monitors a pid once when the same key is tracked again", %{scope: scope} do
      pid = start_process()
      {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key", %{a: 1})
      {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key", %{a: 2})

      assert monitor_count(Tracker.whereis(scope), pid) == 1
    end

    test "keeps the monitor while the pid has another entry", %{scope: scope} do
      pid = start_process()
      {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key_1", %{})
      {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key_2", %{})

      :ok = Rollcall.untrack(pid, scope, "partition", "key_1")

      assert monitor_count(Tracker.whereis(scope), pid) == 1
    end

    test "removes the monitor after the last untrack of the pid", %{scope: scope} do
      pid = start_process()
      other = start_process()
      {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key", %{})
      {:ok, _ref} = Rollcall.track(other, scope, "partition", "key", %{})

      :ok = Rollcall.untrack(pid, scope, "partition", "key")

      tracker = Tracker.whereis(scope)
      assert monitor_count(tracker, pid) == 0
      assert monitor_count(tracker, other) == 1
    end

    test "removes the entries of a pid that exits", %{scope: scope} do
      check_trace(
        fn ->
          pid = start_process()
          {:ok, _ref} = Rollcall.track(pid, scope, "partition_1", "key_1", %{})
          {:ok, _ref} = Rollcall.track(pid, scope, "partition_2", "key_2", %{})

          wait_for_event %{"$kind": :rollcall_tracker_pid_down, scope: ^scope, pid: ^pid} do
            Process.exit(pid, :kill)
          end

          local = Tracker.get_state(scope).local
          assert Local.entries(local, "partition_1") == []
          assert Local.entries(local, "partition_2") == []
        end,
        fn _trace -> :ok end
      )
    end

    test "keeps the entries of other pids when a pid exits", %{scope: scope} do
      check_trace(
        fn ->
          pid = start_process()
          other = start_process()
          {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key", %{})
          {:ok, other_ref} = Rollcall.track(other, scope, "partition", "key", %{})

          wait_for_event %{"$kind": :rollcall_tracker_pid_down, scope: ^scope, pid: ^pid} do
            Process.exit(pid, :kill)
          end

          assert [%{ref: ^other_ref}] = Local.entries(Tracker.get_state(scope).local, "partition")
          assert monitor_count(Tracker.whereis(scope), other) == 1
        end,
        fn trace ->
          assert [] = events(trace, :rollcall_tracker_empty, scope)
        end
      )
    end

    test "increments the version for each pid that exits", %{scope: scope} do
      check_trace(
        fn ->
          pid = start_process()
          {:ok, _ref} = Rollcall.track(pid, scope, "partition", "key", %{})
          version = Tracker.get_state(scope).version

          wait_for_event %{"$kind": :rollcall_tracker_pid_down, scope: ^scope, pid: ^pid} do
            Process.exit(pid, :kill)
          end

          assert Tracker.get_state(scope).version == version + 1
        end,
        fn _trace -> :ok end
      )
    end
  end

  describe "untrack on a scope with no tracker" do
    test "returns :ok and does not start a tracker", %{scope: scope} do
      check_trace(
        fn ->
          assert :ok = Rollcall.untrack(self(), scope, "partition", "key")
        end,
        fn trace ->
          assert [] = events(trace, :rollcall_tracker_started, scope)
          refute scope in Rollcall.scopes()
        end
      )
    end
  end

  # A process that tracks entries for the test. The process runs until the test ends.
  defp start_process do
    pid = spawn(fn -> Process.sleep(:infinity) end)
    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp monitor_count(tracker, pid) do
    {:monitors, monitors} = Process.info(tracker, :monitors)
    Enum.count(monitors, &(&1 == {:process, pid}))
  end
end
