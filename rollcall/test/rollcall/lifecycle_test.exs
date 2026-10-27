defmodule Rollcall.LifecycleTest do
  use Rollcall.Case, async: true

  alias Rollcall.Tracker

  describe "start" do
    test "does not list a scope before the first track", %{scope: scope} do
      refute scope in Rollcall.scopes()
    end

    test "lists a scope after the first track", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})

      assert scope in Rollcall.scopes()
    end

    test "lists a scope once after two tracks", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})

      assert Enum.count(Rollcall.scopes(), &(&1 == scope)) == 1
    end

    test "lists each scope that has an entry", %{scope: scope} do
      other_scope = unique_scope()

      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})
      {:ok, _ref} = Rollcall.track(self(), other_scope, "partition", "key", %{})

      assert scope in Rollcall.scopes()
      assert other_scope in Rollcall.scopes()
    end

    test "does not list a scope with no track", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), unique_scope(), "partition", "key", %{})

      refute scope in Rollcall.scopes()
    end

    test "uses the same tracker for a second track", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
      tracker = Tracker.whereis(scope)

      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})

      assert Tracker.whereis(scope) == tracker
    end

    test "uses one tracker for concurrent first tracks", %{scope: scope} do
      parent = self()

      tasks =
        for n <- 1..50 do
          Task.async(fn ->
            {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_#{n}", %{})
            send(parent, {:tracked, n, Tracker.whereis(scope)})

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

    test "starts a new tracker after the tracker crashes", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
      old_tracker = Tracker.whereis(scope)
      monitor = Process.monitor(old_tracker)
      Process.exit(old_tracker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^old_tracker, :killed}

      assert {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})

      new_tracker = Tracker.whereis(scope)
      assert is_pid(new_tracker)
      refute new_tracker == old_tracker
    end
  end
end
