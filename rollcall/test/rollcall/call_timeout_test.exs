defmodule Rollcall.CallTimeoutTest do
  use Rollcall.Case, async: true

  alias Rollcall.Tracker

  # A suspended tracker handles no message, so a call to it reaches its timeout.
  # The default timeout is 5000 ms. A bound of one second shows that the call used the option.
  @bound_in_us 1_000_000

  setup %{scope: scope, rollcall: rollcall} do
    :ok = Rollcall.ensure_started(rollcall, scope)
    tracker = Tracker.whereis(rollcall, scope)
    :ok = :sys.suspend(tracker)
    on_exit(fn -> if Process.alive?(tracker), do: :sys.resume(tracker) end)

    {:ok, tracker: tracker}
  end

  describe "the option :timeout of track" do
    test "exits at the timeout", %{scope: scope, rollcall: rollcall} do
      {elapsed, reason} =
        :timer.tc(fn ->
          catch_exit(Rollcall.track(rollcall, self(), scope, "partition", "key", %{}, timeout: 50))
        end)

      assert {:timeout, _} = reason
      assert elapsed < @bound_in_us
    end
  end

  describe "the option :timeout of untrack" do
    test "exits at the timeout", %{scope: scope, rollcall: rollcall} do
      {elapsed, reason} =
        :timer.tc(fn ->
          catch_exit(Rollcall.untrack(rollcall, self(), scope, "partition", "key", timeout: 50))
        end)

      assert {:timeout, _} = reason
      assert elapsed < @bound_in_us
    end
  end
end
