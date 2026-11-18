defmodule Realtime.Presence.Comparison.SchedulerTest do
  use ExUnit.Case, async: true

  alias Realtime.Presence.Comparison.Scheduler

  @period 10

  describe "start_link/1" do
    test "starts a sweep each period, and numbers the sweeps from 0" do
      start_scheduler(sweep: notify())

      assert_receive {:swept, 0}, 1_000
      assert_receive {:swept, 1}, 1_000
      assert_receive {:swept, 2}, 1_000
    end

    test "starts no sweep while the previous sweep runs, and starts one at a later tick after it ends" do
      parent = self()

      start_scheduler(
        sweep: fn number ->
          send(parent, {:started, number, self()})
          receive do: (:finish -> :ok)
        end
      )

      assert_receive {:started, 0, sweep}, 1_000

      # Many ticks pass while sweep 0 runs.
      refute_receive {:started, 1, _}, 20 * @period

      send(sweep, :finish)

      # The scheduler starts no sweep at the end of sweep 0. The next tick starts sweep 1. This fails
      # when the scheduler never clears the state of the sweep that ended.
      assert_receive {:started, 1, _}, 1_000
    end

    test "keeps its schedule after a sweep crashes" do
      parent = self()

      start_scheduler(
        sweep: fn
          0 -> raise "boom"
          number -> send(parent, {:swept, number})
        end
      )

      assert_receive {:swept, 1}, 1_000
      assert_receive {:swept, 2}, 1_000
    end
  end

  defp start_scheduler(opts) do
    name = :"scheduler-#{System.unique_integer([:positive])}"
    start_supervised!({Scheduler, Keyword.merge([name: name, period: @period], opts)})
  end

  defp notify do
    parent = self()
    fn number -> send(parent, {:swept, number}) end
  end
end
