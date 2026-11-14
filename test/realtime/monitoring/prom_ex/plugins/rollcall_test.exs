defmodule Realtime.PromEx.Plugins.RollcallTest do
  use Realtime.DataCase, async: false

  alias Realtime.PromEx.Plugins.Rollcall, as: RollcallPlugin
  alias Rollcall.Metrics

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_rollcall

    @impl true
    def plugins, do: [RollcallPlugin]
  end

  @started "realtime_rollcall_tracker_started"
  @stopped "realtime_rollcall_tracker_stopped"
  @purged "realtime_rollcall_peer_purged"
  @silent_ticks "realtime_rollcall_peer_silent_ticks"
  @observations "realtime_rollcall_peer_observations"
  @overdue "realtime_rollcall_peer_observations_overdue"

  setup_all do
    start_supervised!(MetricsTest)
    :ok
  end

  test "counts each tracker start" do
    started_before = metric_value(@started) || 0

    :telemetry.execute(Metrics.tracker_start(), %{}, %{scope: "tenant-a"})

    assert metric_value(@started) == started_before + 1
  end

  test "maps the stop reason to normal, shutdown or crash" do
    reasons = [
      {:normal, "normal"},
      {:shutdown, "shutdown"},
      {{:shutdown, :closed}, "shutdown"},
      {:boom, "crash"},
      {{%RuntimeError{message: "boom"}, []}, "crash"}
    ]

    for {reason, label} <- reasons do
      stopped_before = metric_value(@stopped, reason: label) || 0

      :telemetry.execute(Metrics.tracker_stop(), %{}, %{scope: "tenant-a", reason: reason})

      assert metric_value(@stopped, reason: label) == stopped_before + 1
    end
  end

  test "counts the purges by whether they removed entries" do
    clean_before = metric_value(@purged, stale: "false") || 0
    stale_before = metric_value(@purged, stale: "true") || 0

    :telemetry.execute(Metrics.tracker_peer_purge(), %{entries: 0}, %{scope: "tenant-a", node: :a@host, stale: false})
    :telemetry.execute(Metrics.tracker_peer_purge(), %{entries: 3}, %{scope: "tenant-a", node: :a@host, stale: true})

    assert metric_value(@purged, stale: "false") == clean_before + 1
    assert metric_value(@purged, stale: "true") == stale_before + 1
  end

  describe "the peers event" do
    test "records the most silent peer of each tick in a distribution" do
      le_2_before = metric_value(@silent_ticks <> "_bucket", le: "2.5") || 0
      le_3_before = metric_value(@silent_ticks <> "_bucket", le: "3.5") || 0
      count_before = metric_value(@silent_ticks <> "_count") || 0

      :telemetry.execute(Metrics.tracker_peers(), %{count: 4, overdue_count: 1, max_silent_ticks: 3}, %{
        scope: "tenant-a"
      })

      assert metric_value(@silent_ticks <> "_count") == count_before + 1
      assert metric_value(@silent_ticks <> "_bucket", le: "3.5") == le_3_before + 1
      assert (metric_value(@silent_ticks <> "_bucket", le: "2.5") || 0) == le_2_before
    end

    test "sums the peer observations and the overdue peer observations" do
      observations_before = metric_value(@observations) || 0
      overdue_before = metric_value(@overdue) || 0

      :telemetry.execute(Metrics.tracker_peers(), %{count: 4, overdue_count: 1, max_silent_ticks: 3}, %{
        scope: "tenant-a"
      })

      assert metric_value(@observations) == observations_before + 4
      assert metric_value(@overdue) == overdue_before + 1
    end
  end

  # The metrics are global. A scope label would give each tenant its own series.
  test "no metric has a scope label" do
    scope = "scope-label-check"

    :telemetry.execute(Metrics.tracker_start(), %{}, %{scope: scope})
    :telemetry.execute(Metrics.tracker_stop(), %{}, %{scope: scope, reason: :normal})
    :telemetry.execute(Metrics.tracker_peer_purge(), %{entries: 1}, %{scope: scope, node: :a@host, stale: true})
    :telemetry.execute(Metrics.tracker_peers(), %{count: 1, overdue_count: 1, max_silent_ticks: 2}, %{scope: scope})

    for metric <- [@started, @stopped, @purged, @silent_ticks <> "_count", @observations, @overdue] do
      assert metric_value(metric, scope: scope) == nil
    end
  end

  defp metric_value(metric, tags \\ nil) do
    MetricsHelper.search(PromEx.get_metrics(MetricsTest), metric, tags)
  end
end
