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

  test "ErlSysMon kills RealtimeChannel process with long message queue" do
    start_supervised!({ErlSysMon, config: [{:long_message_queue, {0, 50}}]})
    {:ok, channel_pid} = create_mock_realtime_channel()
    ref = Process.monitor(channel_pid)
    Process.unlink(channel_pid)
    for i <- 1..10_000, do: send(channel_pid, {:test_message, "message_#{i}"})

    assert_receive {:DOWN, ^ref, :process, ^channel_pid, :killed}, 5000
    refute Process.alive?(channel_pid)
  end

  test "ErlSysMon does not kill non-RealtimeChannel processes with long message queue" do
    start_supervised!({ErlSysMon, config: [{:long_message_queue, {0, 50}}]})
    {:ok, regular_pid} = create_regular_process()
    Process.unlink(regular_pid)
    ref = Process.monitor(regular_pid)
    for i <- 1..10_000, do: send(regular_pid, {:test_message, "message_#{i}"})
    Process.sleep(2000)

    assert Process.alive?(regular_pid)

    Process.exit(regular_pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^regular_pid, :killed}
  end

  test "ErlSysMon logs warning for RealtimeChannel long message queue" do
    start_supervised!({ErlSysMon, config: [{:long_message_queue, {0, 50}}]})
    {:ok, channel_pid} = create_mock_realtime_channel()
    Process.unlink(channel_pid)

    log =
      capture_log(fn ->
        for i <- 1..10_000, do: send(channel_pid, {:test_message, "message_#{i}"})
        Process.sleep(1000)
      end)

    assert log =~ "Realtime.ErlSysMon message:"
    assert log =~ "RealtimeWeb.RealtimeChannel"
    assert log =~ "long_message_queue"
  end

  defp create_mock_realtime_channel do
    pid =
      spawn_link(fn ->
        Process.put(:"$initial_call", {RealtimeWeb.RealtimeChannel, :init, 1})

        slow_message_processor()
      end)

    {:ok, pid}
  end

  defp create_regular_process do
    pid =
      spawn_link(fn ->
        Process.put(:"$initial_call", {SomeOtherModule, :init, 1})

        slow_message_processor()
      end)

    {:ok, pid}
  end

  defp slow_message_processor do
    receive do
      {:test_message, _content} ->
        Process.sleep(10)
        slow_message_processor()

      :stop ->
        :ok

      _other ->
        slow_message_processor()
    end
  end
end
