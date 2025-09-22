defmodule Realtime.Monitoring.ErlSysMonTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Realtime.ErlSysMon

  describe "system monitoring" do
    test "logs system monitor events" do
      start_supervised!({ErlSysMon, config: [{:long_message_queue, {1, 100}}]})

      log =
        capture_log(fn ->
          Task.async(fn ->
            Process.register(self(), TestProcess)
            Enum.map(1..1000, &send(self(), &1))
            # Wait  for ErlSysMon to notice
            Process.sleep(4000)
          end)
          |> Task.await()
        end)

      assert log =~ "Realtime.ErlSysMon message:"
      assert log =~ "$initial_call\", {Realtime.Monitoring.ErlSysMonTest"
      assert log =~ "ancestors\", [#{inspect(self())}]"
      assert log =~ "registered_name: TestProcess"
      assert log =~ "message_queue_len: "
      assert log =~ "total_heap_size: "
    end
  end
end
