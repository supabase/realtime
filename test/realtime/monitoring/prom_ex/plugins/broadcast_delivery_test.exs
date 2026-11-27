defmodule Realtime.PromEx.Plugins.BroadcastDeliveryTest do
  use ExUnit.Case, async: false

  alias Realtime.PromEx.Plugins.BroadcastDelivery
  alias RealtimeWeb.BroadcastDeliveryMetrics

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_broadcast_delivery

    @impl true
    def plugins, do: [BroadcastDelivery]
  end

  @metric "realtime_broadcast_delivery_latency"

  setup_all do
    start_supervised!(MetricsTest)
    :ok
  end

  # The SLO queries this metric by name and le label.
  test "exposes the latency in microseconds, with the le labels the SLO matches" do
    under = metric_value("#{@metric}_bucket", origin: "local", le: "1.0e3") || 0
    over = metric_value("#{@metric}_bucket", origin: "local", le: "2.5e3") || 0

    :telemetry.execute(
      BroadcastDeliveryMetrics.event(),
      %{latency: System.convert_time_unit(2_000, :microsecond, :native)},
      %{tenant: "tenant", origin: :local}
    )

    assert metric_value("#{@metric}_bucket", origin: "local", le: "1.0e3") == under
    assert metric_value("#{@metric}_bucket", origin: "local", le: "2.5e3") == over + 1
  end

  # Peep puts a value equal to a bound in the next bucket, so le="1.0e3" means under 1ms.
  test "a sample of exactly 1000µs is counted above le=\"1.0e3\"" do
    under = metric_value("#{@metric}_bucket", origin: "remote", le: "1.0e3") || 0
    over = metric_value("#{@metric}_bucket", origin: "remote", le: "2.5e3") || 0

    :telemetry.execute(
      BroadcastDeliveryMetrics.event(),
      %{latency: System.convert_time_unit(1_000, :microsecond, :native)},
      %{tenant: "tenant", origin: :remote}
    )

    assert metric_value("#{@metric}_bucket", origin: "remote", le: "1.0e3") == under
    assert metric_value("#{@metric}_bucket", origin: "remote", le: "2.5e3") == over + 1
  end

  defp metric_value(metric, expected_tags) do
    MetricsTest
    |> PromEx.get_metrics()
    |> MetricsHelper.search(metric, expected_tags)
  end
end
