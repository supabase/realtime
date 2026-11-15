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
  @send_duration "realtime_rollcall_heartbeat_send_duration"
  @apply_duration "realtime_rollcall_heartbeat_apply_duration"
  @publish_duration "realtime_rollcall_publish_duration"
  @send_entries "realtime_rollcall_heartbeat_send_entries"
  @publish_entries "realtime_rollcall_publish_entries"

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

  # The events carry `duration` in native time units. The metrics are in microseconds. A native
  # value that the plugin does not convert lands far above the last bucket.
  describe "the durations" do
    test "records the send duration in microseconds, by kind" do
      tags = [kind: "snapshot"]
      le_250_before = metric_value(@send_duration <> "_bucket", tags ++ [le: "250.0"]) || 0
      le_500_before = metric_value(@send_duration <> "_bucket", tags ++ [le: "500.0"]) || 0

      :telemetry.execute(Metrics.tracker_heartbeat_send(), %{duration: native(300), entries: 2}, %{
        scope: "tenant-a",
        kind: :snapshot
      })

      assert metric_value(@send_duration <> "_bucket", tags ++ [le: "500.0"]) == le_500_before + 1
      assert (metric_value(@send_duration <> "_bucket", tags ++ [le: "250.0"]) || 0) == le_250_before
    end

    test "records the apply duration in microseconds, by kind" do
      tags = [kind: "diff"]
      count_before = metric_value(@apply_duration <> "_count", tags) || 0
      le_100_before = metric_value(@apply_duration <> "_bucket", tags ++ [le: "100.0"]) || 0

      :telemetry.execute(Metrics.tracker_heartbeat_apply(), %{duration: native(60)}, %{
        scope: "tenant-a",
        node: :a@host,
        kind: :diff
      })

      assert metric_value(@apply_duration <> "_count", tags) == count_before + 1
      assert metric_value(@apply_duration <> "_bucket", tags ++ [le: "100.0"]) == le_100_before + 1
    end

    test "records the publish duration in microseconds, by source" do
      tags = [source: "peer"]
      # Peep writes a bound of 1000 or more in scientific notation.
      le_1000_before = metric_value(@publish_duration <> "_bucket", tags ++ [le: "1.0e3"]) || 0
      le_2500_before = metric_value(@publish_duration <> "_bucket", tags ++ [le: "2.5e3"]) || 0

      :telemetry.execute(Metrics.tracker_publish(), %{duration: native(2_000), entries: 3}, %{
        scope: "tenant-a",
        source: :peer
      })

      assert metric_value(@publish_duration <> "_bucket", tags ++ [le: "2.5e3"]) == le_2500_before + 1
      assert (metric_value(@publish_duration <> "_bucket", tags ++ [le: "1.0e3"]) || 0) == le_1000_before
    end
  end

  describe "the entries" do
    # The values are whole entries. Peep puts a value in a bucket only when it is below the bound, so
    # each bound is half an entry above the value it stands for.
    test "records the entries of each heartbeat that a tracker sends, by kind" do
      tags = [kind: "snapshot"]
      count_before = metric_value(@send_entries <> "_count", tags) || 0
      empty_before = metric_value(@send_entries <> "_bucket", tags ++ [le: "0.5"]) || 0
      le_100_before = metric_value(@send_entries <> "_bucket", tags ++ [le: "100.5"]) || 0
      le_500_before = metric_value(@send_entries <> "_bucket", tags ++ [le: "500.5"]) || 0

      :telemetry.execute(Metrics.tracker_heartbeat_send(), %{duration: native(50), entries: 0}, %{
        scope: "tenant-a",
        kind: :snapshot
      })

      :telemetry.execute(Metrics.tracker_heartbeat_send(), %{duration: native(50), entries: 150}, %{
        scope: "tenant-a",
        kind: :snapshot
      })

      assert metric_value(@send_entries <> "_count", tags) == count_before + 2
      assert metric_value(@send_entries <> "_bucket", tags ++ [le: "0.5"]) == empty_before + 1
      assert metric_value(@send_entries <> "_bucket", tags ++ [le: "500.5"]) == le_500_before + 2
      assert metric_value(@send_entries <> "_bucket", tags ++ [le: "100.5"]) == le_100_before + 1
    end

    test "sums the entries that a tracker publishes, by source" do
      peer_before = metric_value(@publish_entries, source: "peer") || 0
      local_before = metric_value(@publish_entries, source: "local") || 0

      :telemetry.execute(Metrics.tracker_publish(), %{duration: native(50), entries: 3}, %{
        scope: "tenant-a",
        source: :peer
      })

      assert metric_value(@publish_entries, source: "peer") == peer_before + 3
      assert (metric_value(@publish_entries, source: "local") || 0) == local_before
    end
  end

  # The metrics are global. A scope label would give each tenant its own series.
  test "no metric has a scope label" do
    scope = "scope-label-check"

    :telemetry.execute(Metrics.tracker_start(), %{}, %{scope: scope})
    :telemetry.execute(Metrics.tracker_stop(), %{}, %{scope: scope, reason: :normal})
    :telemetry.execute(Metrics.tracker_peer_purge(), %{entries: 1}, %{scope: scope, node: :a@host, stale: true})
    :telemetry.execute(Metrics.tracker_peers(), %{count: 1, overdue_count: 1, max_silent_ticks: 2}, %{scope: scope})

    :telemetry.execute(Metrics.tracker_heartbeat_send(), %{duration: native(50), entries: 1}, %{
      scope: scope,
      kind: :snapshot
    })

    :telemetry.execute(Metrics.tracker_heartbeat_apply(), %{duration: native(50)}, %{
      scope: scope,
      node: :a@host,
      kind: :snapshot
    })

    :telemetry.execute(Metrics.tracker_publish(), %{duration: native(50), entries: 1}, %{scope: scope, source: :local})

    metrics = [
      @started,
      @stopped,
      @purged,
      @silent_ticks <> "_count",
      @observations,
      @overdue,
      @send_duration <> "_count",
      @apply_duration <> "_count",
      @send_entries <> "_count",
      @publish_entries,
      @publish_duration <> "_count"
    ]

    for metric <- metrics do
      assert metric_value(metric, scope: scope) == nil
    end

    # The apply event also carries the node of the peer, which is not a label either.
    assert metric_value(@apply_duration <> "_count", node: "a@host") == nil
  end

  defp native(microseconds), do: System.convert_time_unit(microseconds, :microsecond, :native)

  defp metric_value(metric, tags \\ nil) do
    MetricsHelper.search(PromEx.get_metrics(MetricsTest), metric, tags)
  end
end
