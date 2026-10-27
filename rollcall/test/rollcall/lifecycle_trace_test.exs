defmodule Rollcall.LifecycleTraceTest do
  # The trace collector is global. Tests that use it cannot run concurrently.
  use Rollcall.Case, async: false
  use Snabbkaffex

  alias Rollcall.Tracker

  # check_trace starts the collector and links it to the test process.
  # The collector stays alive until the test process exits.
  # The next test can find a collector that is about to stop.
  # Stop the collector after each test.
  setup do
    on_exit(&Snabbkaffex.stop/0)
  end

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

          {:ok, {:ok, _event}} =
            wait_async_action %{"$kind": :rollcall_tracker_stopped, scope: ^scope},
              timeout: 1_000 do
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

          {:ok, {:ok, _event}} =
            wait_async_action %{"$kind": :rollcall_tracker_stopped, scope: ^scope},
              timeout: 1_000 do
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

          {:ok, {:ok, _event}} =
            wait_async_action %{"$kind": :rollcall_tracker_stopped, scope: ^scope},
              timeout: 1_000 do
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

          {:ok, {:ok, _event}} =
            wait_async_action %{"$kind": :rollcall_tracker_empty, scope: ^scope},
              timeout: 1_000 do
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

    @tag skip: "The tracker does not monitor callers yet"
    test "starts when the last caller exits", %{scope: scope} do
      put_grace(60_000)

      check_trace(
        fn ->
          caller = spawn(fn -> Process.sleep(:infinity) end)
          {:ok, _ref} = Rollcall.track(caller, scope, "partition", "key", %{})
          tracker = Tracker.whereis(scope)

          {:ok, {:ok, _event}} =
            wait_async_action %{"$kind": :rollcall_tracker_empty, scope: ^scope},
              timeout: 1_000 do
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

          {:ok, {:ok, _event}} =
            wait_async_action %{"$kind": :rollcall_tracker_empty, scope: ^scope},
              timeout: 1_000 do
              :ok = Rollcall.untrack(self(), scope, "partition", "key_1")
            end

          {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})

          # The grace period is 50 ms. The wait is four times as long.
          assert :timeout = block_until(%{"$kind": :rollcall_tracker_stopped, scope: ^scope}, 200)
          assert Tracker.whereis(scope) == tracker
        end,
        fn trace ->
          assert [] = events(trace, :rollcall_tracker_stopped, scope)
          assert [_] = events(trace, :rollcall_tracker_started, scope)
        end
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

  defp events(trace, kinds, scope) do
    trace
    |> of_kind(kinds)
    |> Enum.filter(&(&1.scope == scope))
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
