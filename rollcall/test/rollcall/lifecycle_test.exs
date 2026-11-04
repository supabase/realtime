defmodule Rollcall.LifecycleTest do
  use Rollcall.Case, async: true

  alias Rollcall.Tracker

  describe "start" do
    test "does not list a scope before the first track", %{scope: scope, rollcall: rollcall} do
      refute scope in Rollcall.scopes(rollcall)
    end

    test "lists a scope after the first track", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})

      assert scope in Rollcall.scopes(rollcall)
    end

    test "lists a scope once after two tracks", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_1", %{})
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_2", %{})

      assert Enum.count(Rollcall.scopes(rollcall), &(&1 == scope)) == 1
    end

    test "lists each scope that has an entry", %{scope: scope, rollcall: rollcall} do
      other_scope = unique_scope()

      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
      {:ok, _ref} = Rollcall.track(rollcall, self(), other_scope, "partition", "key", %{})

      assert scope in Rollcall.scopes(rollcall)
      assert other_scope in Rollcall.scopes(rollcall)
    end

    test "does not start a tracker for a meta that is not a map", %{scope: scope, rollcall: rollcall} do
      assert_raise FunctionClauseError, fn ->
        Rollcall.track(rollcall, self(), scope, "partition", "key", :not_a_map)
      end

      assert Tracker.whereis(rollcall, scope) == nil
    end

    test "does not list a scope with no track", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), unique_scope(), "partition", "key", %{})

      refute scope in Rollcall.scopes(rollcall)
    end

    test "uses the same tracker for a second track", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_1", %{})
      tracker = Tracker.whereis(rollcall, scope)

      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_2", %{})

      assert Tracker.whereis(rollcall, scope) == tracker
    end

    test "uses one tracker for concurrent first tracks", %{scope: scope, rollcall: rollcall} do
      parent = self()

      tasks =
        for n <- 1..50 do
          Task.async(fn ->
            {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_#{n}", %{})
            send(parent, {:tracked, n, Tracker.whereis(rollcall, scope)})

            receive do
              :done -> :ok
            end
          end)
        end

      trackers =
        for n <- 1..50 do
          assert_receive {:tracked, ^n, tracker}
          tracker
        end

      assert [tracker] = Enum.uniq(trackers)
      assert is_pid(tracker)

      Enum.each(tasks, &send(&1.pid, :done))
      Enum.each(tasks, &Task.await/1)
    end

    test "starts a new tracker after the tracker crashes", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_1", %{})
      old_tracker = Tracker.whereis(rollcall, scope)
      monitor = Process.monitor(old_tracker)
      Process.exit(old_tracker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^old_tracker, :killed}

      assert {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_2", %{})

      new_tracker = Tracker.whereis(rollcall, scope)
      assert is_pid(new_tracker)
      refute new_tracker == old_tracker
    end
  end
end
