defmodule Realtime.PromEx.Plugins.PresenceComparisonTest do
  use ExUnit.Case, async: false

  alias Realtime.PromEx.Plugins.PresenceComparison

  defmodule MetricsTest do
    use PromEx, otp_app: :realtime_test_presence_comparison

    @impl true
    def plugins, do: [PresenceComparison]
  end

  @event [:realtime, :presence, :compare]

  @comparisons "realtime_presence_compare_comparisons"
  @entries "realtime_presence_compare_entries"
  @candidates "realtime_presence_compare_candidates"
  @persistent "realtime_presence_compare_persistent_candidates"
  @rungs_open "realtime_presence_compare_candidate_rungs_open"
  @rungs_converged "realtime_presence_compare_candidate_rungs_converged"
  @rungs_gone "realtime_presence_compare_candidate_rungs_gone"
  @duration "realtime_presence_compare_duration"
  @sweeps "realtime_presence_compare_sweeps"
  @sweep_tenants_listed "realtime_presence_compare_sweep_tenants_listed"
  @sweep_tenants_compared "realtime_presence_compare_sweep_tenants_compared"
  @sweep_duration "realtime_presence_compare_sweep_duration"

  setup_all do
    start_supervised!(MetricsTest)
    :ok
  end

  describe "the :comparison event" do
    test "counts the comparisons by outcome" do
      for outcome <- [:clean, :transient, :persistent, :discarded] do
        before = metric_value(@comparisons, outcome: to_string(outcome)) || 0

        comparison(%{entries: 3, duration: native(5)}, %{outcome: outcome, tenant: "tenant-a"})

        assert metric_value(@comparisons, outcome: to_string(outcome)) == before + 1
      end
    end

    test "sums the entries, and keeps counting after a discarded comparison with no entries" do
      entries_before = metric_value(@entries) || 0
      comparisons_before = metric_value(@comparisons, outcome: "clean") || 0

      comparison(%{duration: native(5)}, %{outcome: :discarded, tenant: "tenant-a"})
      comparison(%{entries: 7, duration: native(5)}, %{outcome: :clean, tenant: "tenant-a"})

      # A handler that raised on the missing measurement would be detached, and miss the second event.
      assert metric_value(@entries) == entries_before + 7
      assert metric_value(@comparisons, outcome: "clean") == comparisons_before + 1
    end

    # The events carry the duration in native time units. The metric is in milliseconds. A native
    # value that the plugin does not convert lands far above the last bound.
    test "records the duration in milliseconds" do
      count_before = metric_value(@duration <> "_count") || 0
      le_1500_before = metric_value(@duration <> "_bucket", le: "1.5e3") || 0
      le_3500_before = metric_value(@duration <> "_bucket", le: "3.5e3") || 0

      comparison(%{entries: 1, duration: native(2_500)}, %{outcome: :transient, tenant: "tenant-a"})

      assert metric_value(@duration <> "_count") == count_before + 1
      assert metric_value(@duration <> "_bucket", le: "3.5e3") == le_3500_before + 1
      assert (metric_value(@duration <> "_bucket", le: "1.5e3") || 0) == le_1500_before
    end
  end

  describe "the :candidates and :persistent events" do
    test "sum the candidates at the first read, by kind" do
      for kind <- [:missing, :ghost] do
        before = metric_value(@candidates, kind: to_string(kind)) || 0

        :telemetry.execute(@event ++ [:candidates], %{count: 4}, %{kind: kind, tenant: "tenant-a"})

        assert metric_value(@candidates, kind: to_string(kind)) == before + 4
      end
    end

    test "sum the persistent candidates, by kind" do
      for kind <- [:missing, :ghost] do
        before = metric_value(@persistent, kind: to_string(kind)) || 0

        :telemetry.execute(@event ++ [:persistent], %{count: 2}, %{kind: kind, tenant: "tenant-a"})

        assert metric_value(@persistent, kind: to_string(kind)) == before + 2
      end
    end
  end

  describe "the :rung event" do
    test "sums the open, the converged and the gone candidates, by rung and kind" do
      tags = [rung: "3000", kind: "missing"]
      open_before = metric_value(@rungs_open, tags) || 0
      converged_before = metric_value(@rungs_converged, tags) || 0
      gone_before = metric_value(@rungs_gone, tags) || 0

      :telemetry.execute(@event ++ [:rung], %{open: 2, converged: 3, gone: 1}, %{rung: 3_000, kind: :missing})

      assert metric_value(@rungs_open, tags) == open_before + 2
      assert metric_value(@rungs_converged, tags) == converged_before + 3
      assert metric_value(@rungs_gone, tags) == gone_before + 1
    end
  end

  describe "the :sweep event" do
    test "counts the sweeps and sums the tenants that a sweep listed and compared" do
      sweeps_before = metric_value(@sweeps) || 0
      listed_before = metric_value(@sweep_tenants_listed) || 0
      compared_before = metric_value(@sweep_tenants_compared) || 0

      sweep(%{tenants_listed: 40, tenants_compared: 5, duration: native(100)})

      assert metric_value(@sweeps) == sweeps_before + 1
      assert metric_value(@sweep_tenants_listed) == listed_before + 40
      assert metric_value(@sweep_tenants_compared) == compared_before + 5
    end

    test "records the duration in milliseconds" do
      count_before = metric_value(@sweep_duration <> "_count") || 0
      le_15000_before = metric_value(@sweep_duration <> "_bucket", le: "1.5e4") || 0
      le_30000_before = metric_value(@sweep_duration <> "_bucket", le: "3.0e4") || 0

      sweep(%{tenants_listed: 1, tenants_compared: 1, duration: native(20_000)})

      assert metric_value(@sweep_duration <> "_count") == count_before + 1
      assert metric_value(@sweep_duration <> "_bucket", le: "3.0e4") == le_30000_before + 1
      assert (metric_value(@sweep_duration <> "_bucket", le: "1.5e4") || 0) == le_15000_before
    end
  end

  test "no metric of the comparison has a tenant tag" do
    comparison(%{entries: 1, duration: native(5)}, %{outcome: :clean, tenant: "tenant-secret"})
    :telemetry.execute(@event ++ [:candidates], %{count: 1}, %{kind: :missing, tenant: "tenant-secret"})
    :telemetry.execute(@event ++ [:persistent], %{count: 1}, %{kind: :missing, tenant: "tenant-secret"})

    lines =
      MetricsTest
      |> PromEx.get_metrics()
      |> IO.iodata_to_binary()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "realtime_presence_compare_"))

    assert lines != []
    refute Enum.any?(lines, &(String.contains?(&1, "tenant=") or String.contains?(&1, "tenant-secret")))
  end

  defp comparison(measurements, metadata), do: :telemetry.execute(@event ++ [:comparison], measurements, metadata)

  defp sweep(measurements), do: :telemetry.execute(@event ++ [:sweep], measurements, %{})

  defp native(milliseconds), do: System.convert_time_unit(milliseconds, :millisecond, :native)

  defp metric_value(metric, tags \\ nil) do
    MetricsHelper.search(PromEx.get_metrics(MetricsTest), metric, tags)
  end
end
