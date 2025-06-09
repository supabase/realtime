defmodule Realtime.Monitoring.ErlSysMonTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Realtime.ErlSysMon

  describe "system monitoring" do
    test "logs system monitor events" do
      start_supervised!({ErlSysMon, config: [{:long_message_queue, {1, 10}}]})

      assert capture_log(fn ->
               Task.async(fn ->
                 Enum.map(1..1000, &send(self(), &1))
                 # Wait  for ErlSysMon to notice
                 Process.sleep(4000)
               end)
               |> Task.await()
             end) =~ "Realtime.ErlSysMon message:"
    end
  end
end
