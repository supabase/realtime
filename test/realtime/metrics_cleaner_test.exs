defmodule Realtime.MetricsCleanerTest do
  # async: false due to potentially polluting metrics with other tenant metrics from other tests
  use Realtime.DataCase, async: false

  alias Realtime.MetricsCleaner
  alias Realtime.Tenants.Connect

  setup do
    interval = Application.get_env(:realtime, :metrics_cleaner_schedule_timer_in_ms)
    Application.put_env(:realtime, :metrics_cleaner_schedule_timer_in_ms, 100)
    on_exit(fn -> Application.put_env(:realtime, :metrics_cleaner_schedule_timer_in_ms, interval) end)

    tenant = Containers.checkout_tenant(run_migrations: true)

    %{tenant: tenant}
  end

  describe "metrics cleanup" do
    test "cleans up metrics for users that have been disconnected", %{tenant: %{external_id: external_id}} do
      start_supervised!(MetricsCleaner)
      {:ok, _} = Connect.lookup_or_start_connection(external_id)
      # Wait for promex to collect the metrics
      Process.sleep(6000)

      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 10, connected_cluster: 10, limit: 100},
        %{tenant: external_id}
      )

      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 20, connected_cluster: 20, limit: 100},
        %{tenant: "disconnected-tenant"}
      )

      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()

      assert String.contains?(metrics, external_id)
      assert String.contains?(metrics, "disconnected-tenant")

      # Wait for clenaup to run
      Process.sleep(200)

      metrics = Realtime.PromEx.get_metrics() |> IO.iodata_to_binary()

      assert String.contains?(metrics, external_id)
      refute String.contains?(metrics, "disconnected-tenant")
    end
  end
end
