defmodule Realtime.MetricsCleanerTest do
  # async: false due to potentially polluting metrics with other tenant metrics from other tests
  use Realtime.DataCase, async: false
  alias Realtime.MetricsCleaner

  setup do
    interval = Application.get_env(:realtime, :metrics_cleaner_schedule_timer_in_ms)
    Application.put_env(:realtime, :metrics_cleaner_schedule_timer_in_ms, 100)
    tenant = Containers.checkout_tenant(run_migrations: true)

    on_exit(fn ->
      Application.put_env(:realtime, :metrics_cleaner_schedule_timer_in_ms, interval)
    end)

    %{tenant: tenant}
  end

  describe "metrics cleanup" do
    test "cleans up metrics for users that have been disconnected", %{
      tenant: %{external_id: external_id}
    } do
      start_supervised!(MetricsCleaner)
      {:ok, _} = Realtime.Tenants.Connect.lookup_or_start_connection(external_id)
      # Wait for promex to collect the metrics
      Process.sleep(6000)

      Realtime.Telemetry.execute(
        [:realtime, :connections],
        %{connected: 10, connected_cluster: 10, limit: 100},
        %{tenant: external_id}
      )

      assert Realtime.PromEx.Metrics
             |> :ets.select([{{{:_, %{tenant: :"$1"}}, :_}, [], [:"$1"]}])
             |> Enum.any?(&(&1 == external_id))

      Realtime.Tenants.Connect.shutdown(external_id)
      Process.sleep(200)

      refute Realtime.PromEx.Metrics
             |> :ets.select([{{{:_, %{tenant: :"$1"}}, :_}, [], [:"$1"]}])
             |> Enum.any?(&(&1 == external_id))
    end
  end
end
