defmodule Realtime.PromEx.Plugins.ClientRequestsTest do
  use Realtime.DataCase, async: false

  alias Realtime.PromEx.Plugins.ClientRequests
  alias RealtimeWeb.RequestMetrics

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_client_requests

    @impl true
    def plugins, do: [ClientRequests]
  end

  setup_all do
    start_supervised!(MetricsTest)
    :ok
  end

  # The SLO in k8s-observability selects on this exact name and these labels.
  test "exposes realtime_client_requests_total with request, transport, outcome and reason" do
    tags = [request: "broadcast", transport: "ws", outcome: "rejected", reason: "unauthorized"]
    before = metric_value("realtime_client_requests_total", tags) || 0

    RequestMetrics.record(:broadcast, :ws, {:rejected, :unauthorized})

    assert metric_value("realtime_client_requests_total", tags) == before + 1
  end

  test "a success has reason none" do
    tags = [request: "broadcast", transport: "ws", outcome: "success", reason: "none"]
    before = metric_value("realtime_client_requests_total", tags) || 0

    RequestMetrics.record(:broadcast, :ws, :success)

    assert metric_value("realtime_client_requests_total", tags) == before + 1
  end

  defp metric_value(metric, expected_tags) do
    MetricsTest
    |> PromEx.get_metrics()
    |> MetricsHelper.search(metric, expected_tags)
  end
end
