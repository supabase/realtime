defmodule Realtime.MetricsCleanerTest do
  use Realtime.DataCase, async: true

  alias Realtime.MetricsCleaner
  alias Realtime.Tenants.Connect

  describe "metrics cleanup - vacant websockets" do
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

      # Nothing changes yet (threshold not reached)
      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()

      assert String.contains?(metrics, "tenant=\"occupied-tenant\"")
      assert String.contains?(metrics, "tenant=\"vacant-tenant1\"")
      assert String.contains?(metrics, "tenant=\"vacant-tenant2\"")

      # Wait for threshold to pass and cleanup to run
      Process.sleep(2200)

      # vacant tenant metrics are now gone
      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()

      assert String.contains?(metrics, "tenant=\"occupied-tenant\"")
      refute String.contains?(metrics, "tenant=\"vacant-tenant1\"")
      refute String.contains?(metrics, "tenant=\"vacant-tenant2\"")
    end

    test "does not clean up metrics if websockets reconnect before threshold" do
      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 1, connected_cluster: 10, limit: 100},
        %{tenant: "reconnect-tenant"}
      )

      pid = spawn_link(fn -> Process.sleep(:infinity) end)

      Beacon.join(:users, "reconnect-tenant", pid)

      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()
      assert String.contains?(metrics, "tenant=\"reconnect-tenant\"")

      start_supervised!(
        {MetricsCleaner, [metrics_cleaner_schedule_timer_in_ms: 100, vacant_metric_threshold_in_seconds: 1]}
      )

      # Disconnect
      Beacon.leave(:users, "reconnect-tenant", pid)
      Process.sleep(500)

      # Reconnect before threshold
      pid2 = spawn_link(fn -> Process.sleep(:infinity) end)
      Beacon.join(:users, "reconnect-tenant", pid2)

      # Wait for cleanup to run
      Process.sleep(2200)

      # Metrics should still be present
      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()
      assert String.contains?(metrics, "tenant=\"reconnect-tenant\"")
    end
  end

  describe "metrics cleanup - disconnected tenants" do
    test "cleans up metrics for tenants that have been unregistered" do
      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 1, connected_cluster: 10, limit: 100},
        %{tenant: "connected-tenant"}
      )

      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 0, connected_cluster: 20, limit: 100},
        %{tenant: "disconnected-tenant1"}
      )

      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 0, connected_cluster: 20, limit: 100},
        %{tenant: "disconnected-tenant2"}
      )

      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()

      assert String.contains?(metrics, "tenant=\"connected-tenant\"")
      assert String.contains?(metrics, "tenant=\"disconnected-tenant1\"")
      assert String.contains?(metrics, "tenant=\"disconnected-tenant2\"")

      start_supervised!(
        {MetricsCleaner, [metrics_cleaner_schedule_timer_in_ms: 100, vacant_metric_threshold_in_seconds: 1]}
      )

      # Simulate tenant registration (connected)
      :telemetry.execute([:syn, Connect, :registered], %{}, %{name: "connected-tenant"})

      # Simulate tenant unregistration (disconnected)
      :telemetry.execute([:syn, Connect, :unregistered], %{}, %{name: "disconnected-tenant1"})
      :telemetry.execute([:syn, Connect, :unregistered], %{}, %{name: "disconnected-tenant2"})

      # Wait for clean up to run
      Process.sleep(200)

      # Nothing changes yet (threshold not reached)
      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()

      assert String.contains?(metrics, "tenant=\"connected-tenant\"")
      assert String.contains?(metrics, "tenant=\"disconnected-tenant1\"")
      assert String.contains?(metrics, "tenant=\"disconnected-tenant2\"")

      # Wait for threshold to pass and cleanup to run
      Process.sleep(2200)

      # disconnected tenant metrics are now gone
      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()

      assert String.contains?(metrics, "tenant=\"connected-tenant\"")
      refute String.contains?(metrics, "tenant=\"disconnected-tenant1\"")
      refute String.contains?(metrics, "tenant=\"disconnected-tenant2\"")
    end

    test "does not clean up metrics if tenant reconnects before threshold" do
      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 1, connected_cluster: 10, limit: 100},
        %{tenant: "reconnect-tenant"}
      )

      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()
      assert String.contains?(metrics, "tenant=\"reconnect-tenant\"")

      start_supervised!(
        {MetricsCleaner, [metrics_cleaner_schedule_timer_in_ms: 100, vacant_metric_threshold_in_seconds: 1]}
      )

      # Simulate tenant unregistration
      :telemetry.execute([:syn, Connect, :unregistered], %{}, %{name: "reconnect-tenant"})
      Process.sleep(500)

      # Re-register before threshold
      :telemetry.execute([:syn, Connect, :registered], %{}, %{name: "reconnect-tenant"})

      # Wait for cleanup to run
      Process.sleep(2200)

      # Metrics should still be present
      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()
      assert String.contains?(metrics, "tenant=\"reconnect-tenant\"")
    end
  end
end
