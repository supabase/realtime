defmodule Rollcall.LifecycleTraceTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Rollcall.TraceHelpers

  alias Rollcall.Tracker
  alias Rollcall.Tracker.Local

  describe "stop" do
    setup do
      put_grace(10)
    end

    test "stops the tracker when the grace period ends", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
          tracker = Tracker.whereis(scope)
          monitor = Process.monitor(tracker)

          wait_for_event %{"$kind": :rollcall_tracker_stopped, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key")
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

          :ok = Rollcall.untrack(self(), scope, "partition", "key_1")
          tp(:test_first_untrack_done, %{scope: scope})

          wait_for_event %{"$kind": :rollcall_tracker_stopped, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key_2")
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

    test "starts a new tracker for a track after the stop", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
          old_tracker = Tracker.whereis(scope)
          monitor = Process.monitor(old_tracker)

          wait_for_event %{"$kind": :rollcall_tracker_stopped, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key")
          end

          assert_receive {:DOWN, ^monitor, :process, ^old_tracker, :normal}

          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
          new_tracker = Tracker.whereis(scope)

          assert is_pid(new_tracker)
          refute new_tracker == old_tracker
        end,
        fn trace ->
          assert [_, _] = events(trace, :rollcall_tracker_started, scope)
        end
      )
    end
  end

  describe "grace period" do
    test "keeps the empty tracker running", %{scope: scope} do
      put_grace(60_000)

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
      put_grace(60_000)

      check_trace(
        fn ->
          caller = spawn(fn -> Process.sleep(:infinity) end)
          {:ok, _ref} = Rollcall.track(caller, scope, "partition", "key", %{})
          tracker = Tracker.whereis(scope)

          wait_for_event %{"$kind": :rollcall_tracker_empty, scope: ^scope} do
            Process.exit(caller, :kill)
          end

          assert Process.alive?(tracker)
        end,
        fn trace ->
          assert [] = events(trace, :rollcall_tracker_stopped, scope)
        end
      )
    end

    test "ends without a stop when a track arrives", %{scope: scope} do
      put_grace(50)

      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
          tracker = Tracker.whereis(scope)

          wait_for_event %{"$kind": :rollcall_tracker_empty, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key_1")
          end

          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})

          # The grace period is 50 ms. The wait is four times as long.
          refute_event(%{"$kind": :rollcall_tracker_stopped, scope: ^scope}, 200)
          assert Tracker.whereis(scope) == tracker
        end,
        fn trace ->
          assert [] = events(trace, :rollcall_tracker_stopped, scope)
          assert [_] = events(trace, :rollcall_tracker_started, scope)
        end
      )
    end
  end

  describe "monitors" do
    setup do
      put_grace(60_000)
    end

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

  describe "incarnation" do
    setup do
      put_grace(10)
    end

    test "is greater for a tracker that starts after the previous tracker stopped", %{
      scope: scope
    } do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
          first = Tracker.get_state(scope).incarnation
          tracker = Tracker.whereis(scope)
          monitor = Process.monitor(tracker)

          wait_for_event %{"$kind": :rollcall_tracker_stopped, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key")
          end

          assert_receive {:DOWN, ^monitor, :process, ^tracker, :normal}

          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})

          assert Tracker.get_state(scope).incarnation > first
        end,
        fn _trace -> :ok end
      )
    end

    test "restarts the version at 1 for the first track of the new tracker", %{scope: scope} do
      check_trace(
        fn ->
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})
          tracker = Tracker.whereis(scope)
          monitor = Process.monitor(tracker)

          wait_for_event %{"$kind": :rollcall_tracker_stopped, scope: ^scope} do
            :ok = Rollcall.untrack(self(), scope, "partition", "key_1")
            :ok = Rollcall.untrack(self(), scope, "partition", "key_2")
          end

          assert_receive {:DOWN, ^monitor, :process, ^tracker, :normal}

          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})

          assert Tracker.get_state(scope).version == 1
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

  defp put_grace(milliseconds) do
    previous = Application.fetch_env(:rollcall, :empty_grace)
    Application.put_env(:rollcall, :empty_grace, milliseconds)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:rollcall, :empty_grace, value)
        :error -> Application.delete_env(:rollcall, :empty_grace)
      end
    end)
  end
end
