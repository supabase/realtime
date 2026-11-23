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

    test "starts the next sweep one period after the previous sweep ends" do
      parent = self()

      start_scheduler(
        period: 100,
        sweep: fn number ->
          send(parent, {:started, number, self()})
          receive do: (:finish -> :ok)
        end
      )

      assert_receive {:started, 0, sweep}, 1_000

      # No sweep overlaps sweep 0. The hold is 1.5 periods long.
      refute_receive {:started, 1, _}, 150

      send(sweep, :finish)

      # A fixed rate starts sweep 1 at the next tick, 50 ms after the end of sweep 0. A fixed delay
      # waits a full period from the end of sweep 0.
      refute_receive {:started, 1, _}, 80
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
