defmodule Realtime.MetricsCleanerTest do
  use Realtime.DataCase, async: true

  alias Realtime.MetricsCleaner

  describe "metrics cleanup" do
    test "cleans up metrics for users that have been disconnected" do
      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 1, connected_cluster: 10, limit: 100},
        %{tenant: "occupied-tenant"}
      )

      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 0, connected_cluster: 20, limit: 100},
        %{tenant: "vacant-tenant1"}
      )

      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 0, connected_cluster: 20, limit: 100},
        %{tenant: "vacant-tenant2"}
      )

      pid1 = spawn_link(fn -> Process.sleep(:infinity) end)
      pid2 = spawn_link(fn -> Process.sleep(:infinity) end)
      pid3 = spawn_link(fn -> Process.sleep(:infinity) end)

      Beacon.join(:users, "occupied-tenant", pid1)
      Beacon.join(:users, "vacant-tenant1", pid2)
      Beacon.join(:users, "vacant-tenant2", pid3)

      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()

      assert String.contains?(metrics, "tenant=\"occupied-tenant\"")
      assert String.contains?(metrics, "tenant=\"vacant-tenant1\"")
      assert String.contains?(metrics, "tenant=\"vacant-tenant2\"")

      start_supervised!(
        {MetricsCleaner, [metrics_cleaner_schedule_timer_in_ms: 100, vacant_metric_threshold_in_seconds: 1]}
      )

      # Now let's disconnect vacant tenants
      Beacon.leave(:users, "vacant-tenant1", pid2)
      Beacon.leave(:users, "vacant-tenant2", pid3)

      # Wait for clean up to run
      Process.sleep(200)

      # Nothing changes
      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()

      assert String.contains?(metrics, "tenant=\"occupied-tenant\"")
      assert String.contains?(metrics, "tenant=\"vacant-tenant1\"")
      assert String.contains?(metrics, "tenant=\"vacant-tenant2\"")

      # Wait for clean up to run again
      Process.sleep(2100)

      # vacant tenant metrics are now gone
      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()

      assert String.contains?(metrics, "tenant=\"occupied-tenant\"")
      refute String.contains?(metrics, "tenant=\"vacant-tenant1\"")
      refute String.contains?(metrics, "tenant=\"vacant-tenant2\"")
    end
  end
end
