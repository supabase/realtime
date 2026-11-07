defmodule Rollcall.TrackerTest do
  use Rollcall.Case, async: true

  alias Rollcall.Tracker

  describe "whereis/2" do
    test "returns nil when no tracker runs for the scope", %{scope: scope, rollcall: rollcall} do
      assert Tracker.whereis(rollcall, scope) == nil
    end

    test "returns the pid of the tracker for the scope", %{scope: scope, rollcall: rollcall} do
      pid = start_supervised!({Tracker, {scope, name: rollcall}})

      assert Tracker.whereis(rollcall, scope) == pid
    end
  end

  describe "track/6" do
    test "returns a different string ref for each track", %{scope: scope, rollcall: rollcall} do
      refs =
        for n <- 1..1000 do
          {:ok, ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_#{n}", %{})
          ref
        end

      assert Enum.all?(refs, &is_binary/1)
      assert refs |> Enum.uniq() |> length() == 1000
    end
  end

  describe "start_link/1" do
    test "returns an error when a tracker runs for the scope", %{scope: scope, rollcall: rollcall} do
      pid = start_supervised!({Tracker, {scope, name: rollcall}})

      assert {:error, {:already_started, ^pid}} = Tracker.start_link({scope, name: rollcall})
    end

    test "sets the process label", %{scope: scope, rollcall: rollcall} do
      pid = start_supervised!({Tracker, {scope, name: rollcall}})

      assert Process.info(pid, :label) == {:label, {:rollcall_tracker, scope}}
    end
  end
end
