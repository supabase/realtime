defmodule Realtime.ErlSysMonTest do
  use ExUnit.Case
  import ExUnit.CaptureLog
  alias Realtime.ErlSysMon

  describe "system monitoring" do
    test "logs system monitor events" do
      start_supervised!({ErlSysMon, [{:long_message_queue, {1, 10}}]})

      assert capture_log(fn ->
               Task.async(fn -> Enum.map(1..10000, &send(self(), &1)) end)
               |> Task.await()
             end) =~ "Realtime.ErlSysMon message: "
    end
  end
end
