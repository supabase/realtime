defmodule Rollcall.TrackerTest do
  use Rollcall.Case, async: true

  alias Rollcall.Tracker

  describe "whereis/1" do
    test "returns nil when no tracker runs for the scope", %{scope: scope} do
      assert Tracker.whereis(scope) == nil
    end

    test "returns the pid of the tracker for the scope", %{scope: scope} do
      pid = start_supervised!({Tracker, scope})

      assert Tracker.whereis(scope) == pid
    end
  end

  describe "start_link/1" do
    test "returns an error when a tracker runs for the scope", %{scope: scope} do
      pid = start_supervised!({Tracker, scope})

      assert {:error, {:already_started, ^pid}} = Tracker.start_link(scope)
    end

    test "sets the process label", %{scope: scope} do
      pid = start_supervised!({Tracker, scope})

      assert Process.info(pid, :label) == {:label, {:rollcall_tracker, scope}}
    end
  end
end
