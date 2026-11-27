defmodule RealtimeWeb.BroadcastDeliveryMetricsTest do
  use ExUnit.Case, async: true

  alias RealtimeWeb.BroadcastDeliveryMetrics

  setup do
    ref = make_ref()
    test_pid = self()

    :telemetry.attach(
      ref,
      BroadcastDeliveryMetrics.event(),
      fn _, measurements, metadata, _ ->
        if self() == test_pid, do: send(test_pid, {:delivery, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(ref) end)
  end

  test "records one sample per dispatch, ending at the last send" do
    BroadcastDeliveryMetrics.with_timing("tenant", :local, fn ->
      BroadcastDeliveryMetrics.send_push(self(), :first)
      Process.sleep(10)
      BroadcastDeliveryMetrics.send_push(self(), :second)
      Process.sleep(50)
    end)

    assert_receive :first
    assert_receive :second
    assert_receive {:delivery, %{latency: latency}, %{tenant: "tenant", origin: :local}}
    assert latency >= System.convert_time_unit(10, :millisecond, :native)
    assert latency < System.convert_time_unit(50, :millisecond, :native)
    refute_receive {:delivery, _, _}
  end

  test "records nothing when no socket was sent to" do
    BroadcastDeliveryMetrics.with_timing("tenant", :local, fn -> :ok end)

    refute_receive {:delivery, _, _}
  end

  test "send_push/2 sends without recording when no clock is running" do
    BroadcastDeliveryMetrics.send_push(self(), :push)

    assert_receive :push
    refute_receive {:delivery, _, _}
  end

  test "records nothing and stops the clock when the dispatch raises after a send" do
    assert_raise RuntimeError, fn ->
      BroadcastDeliveryMetrics.with_timing("tenant", :local, fn ->
        BroadcastDeliveryMetrics.send_push(self(), :push)
        raise "boom"
      end)
    end

    assert_receive :push
    refute_receive {:delivery, _, _}

    BroadcastDeliveryMetrics.send_push(self(), :after)
    assert_receive :after
    refute_receive {:delivery, _, _}
  end

  test "a nested clock restores the outer one" do
    BroadcastDeliveryMetrics.with_timing("outer", :local, fn ->
      BroadcastDeliveryMetrics.with_timing("inner", :local, fn -> :ok end)
      BroadcastDeliveryMetrics.send_push(self(), :push)
    end)

    assert_receive {:delivery, _, %{tenant: "outer"}}
    refute_receive {:delivery, _, _}
  end
end
