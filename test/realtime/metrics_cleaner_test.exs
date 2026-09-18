defmodule Realtime.MetricsCleanerTest do
  use Realtime.DataCase, async: true

  alias Realtime.MetricsCleaner
  alias Realtime.Tenants.Connect
  alias Forum.Census

  # `get_metrics/0` renders the whole Prometheus payload, so probe it at the cleaner's own
  # schedule rather than at the assertion macros' much finer default.
  @probe_interval_ms 50

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

      Census.join(:users, "occupied-tenant", pid1)
      Census.join(:users, "vacant-tenant1", pid2)
      Census.join(:users, "vacant-tenant2", pid3)

      assert exported?("occupied-tenant")
      assert exported?("vacant-tenant1")
      assert exported?("vacant-tenant2")

      start_supervised!(
        {MetricsCleaner, [metrics_cleaner_schedule_timer_in_ms: 100, vacant_metric_threshold_in_seconds: 1]}
      )

      # Now let's disconnect vacant tenants
      Census.leave(:users, "vacant-tenant1", pid2)
      Census.leave(:users, "vacant-tenant2", pid3)

      # The cleaner runs every 100ms but must not evict before the 1s threshold: assert the
      # metrics survive every run in that window rather than sampling once at the end of it.
      assert_always(
        exported?("occupied-tenant") and exported?("vacant-tenant1") and exported?("vacant-tenant2"),
        timeout: 200,
        interval: @probe_interval_ms
      )

      # Past the threshold the next run evicts them.
      assert_eventually(
        not exported?("vacant-tenant1") and not exported?("vacant-tenant2"),
        timeout: 3_000,
        interval: @probe_interval_ms
      )

      assert exported?("occupied-tenant")
    end

    test "does not clean up metrics if websockets reconnect before threshold" do
      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 1, connected_cluster: 10, limit: 100},
        %{tenant: "reconnect-tenant"}
      )

      pid = spawn_link(fn -> Process.sleep(:infinity) end)

      Census.join(:users, "reconnect-tenant", pid)

      assert exported?("reconnect-tenant")

      start_supervised!(
        {MetricsCleaner, [metrics_cleaner_schedule_timer_in_ms: 100, vacant_metric_threshold_in_seconds: 1]}
      )

      # Disconnect
      Census.leave(:users, "reconnect-tenant", pid)
      Process.sleep(500)

      # Reconnect before threshold
      pid2 = spawn_link(fn -> Process.sleep(:infinity) end)
      Census.join(:users, "reconnect-tenant", pid2)

      # Every cleaner run past the threshold must leave the reconnected tenant alone, so assert
      # across the whole window rather than at one instant in it.
      assert_always(exported?("reconnect-tenant"), timeout: 2_200, interval: @probe_interval_ms)
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

      assert exported?("connected-tenant")
      assert exported?("disconnected-tenant1")
      assert exported?("disconnected-tenant2")

      start_supervised!(
        {MetricsCleaner, [metrics_cleaner_schedule_timer_in_ms: 100, vacant_metric_threshold_in_seconds: 1]}
      )

      # Simulate tenant registration (connected)
      :telemetry.execute([:syn, Connect, :registered], %{}, %{name: "connected-tenant"})

      # Simulate tenant unregistration (disconnected)
      :telemetry.execute([:syn, Connect, :unregistered], %{}, %{name: "disconnected-tenant1"})
      :telemetry.execute([:syn, Connect, :unregistered], %{}, %{name: "disconnected-tenant2"})

      # The cleaner runs every 100ms but must not evict before the 1s threshold: assert the
      # metrics survive every run in that window rather than sampling once at the end of it.
      assert_always(
        exported?("connected-tenant") and exported?("disconnected-tenant1") and exported?("disconnected-tenant2"),
        timeout: 200,
        interval: @probe_interval_ms
      )

      # Past the threshold the next run evicts them.
      assert_eventually(
        not exported?("disconnected-tenant1") and not exported?("disconnected-tenant2"),
        timeout: 3_000,
        interval: @probe_interval_ms
      )

      assert exported?("connected-tenant")
    end

    test "does not clean up metrics if tenant reconnects before threshold" do
      :telemetry.execute(
        [:realtime, :connections],
        %{connected: 1, connected_cluster: 10, limit: 100},
        %{tenant: "reconnect-tenant"}
      )

      assert exported?("reconnect-tenant")

      start_supervised!(
        {MetricsCleaner, [metrics_cleaner_schedule_timer_in_ms: 100, vacant_metric_threshold_in_seconds: 1]}
      )

      # Simulate tenant unregistration
      :telemetry.execute([:syn, Connect, :unregistered], %{}, %{name: "reconnect-tenant"})
      Process.sleep(500)

      # Re-register before threshold
      :telemetry.execute([:syn, Connect, :registered], %{}, %{name: "reconnect-tenant"})

      # Every cleaner run past the threshold must leave the reconnected tenant alone, so assert
      # across the whole window rather than at one instant in it.
      assert_always(exported?("reconnect-tenant"), timeout: 2_200, interval: @probe_interval_ms)
    end
  end

  describe "handle_info/2 unexpected message" do
    test "logs error for unexpected messages" do
      import ExUnit.CaptureLog

      pid =
        start_supervised!(
          {MetricsCleaner, [metrics_cleaner_schedule_timer_in_ms: 60_000, vacant_metric_threshold_in_seconds: 600]}
        )

      log =
        capture_log(fn ->
          send(pid, :something_unexpected)
          # Queued behind the message above, so it returns only once that clause has logged.
          :sys.get_state(pid)
        end)

      assert log =~ "Unexpected message"
      assert log =~ "something_unexpected"
    end
  end

  describe "recently_vacated_tenants/2" do
    test "returns tenants that vacated within the threshold minus the margin" do
      table = :ets.new(:test_recently_vacated, [:set, :public, :named_table])
      now = DateTime.to_unix(DateTime.utc_now(), :second)

      # threshold 600s, margin 60s: only vacancies younger than 540s are returned
      :ets.insert(table, {"just-vacated", now})
      :ets.insert(table, {"vacated-a-while-ago", now - 500})
      :ets.insert(table, {"about-to-be-pruned", now - 580})
      :ets.insert(table, {"past-threshold", now - 700})

      assert Enum.sort(MetricsCleaner.recently_vacated_tenants(table, 600)) == ["just-vacated", "vacated-a-while-ago"]
    end

    test "returns an empty list when the table does not exist" do
      assert MetricsCleaner.recently_vacated_tenants(:does_not_exist, 600) == []
    end

    test "tracks vacancies from the running MetricsCleaner" do
      start_supervised!(
        {MetricsCleaner,
         [
           metrics_cleaner_schedule_timer_in_ms: 60_000,
           vacant_metric_threshold_in_seconds: 600,
           vacant_websockets_table: :test_running_vacant
         ]}
      )

      pid = spawn_link(fn -> Process.sleep(:infinity) end)
      Census.join(:users, "running-tenant", pid)
      Census.leave(:users, "running-tenant", pid)

      assert MetricsCleaner.recently_vacated_tenants(:test_running_vacant, 600) == ["running-tenant"]

      # Getting a websocket back removes the vacancy
      pid2 = spawn_link(fn -> Process.sleep(:infinity) end)
      Census.join(:users, "running-tenant", pid2)

      assert MetricsCleaner.recently_vacated_tenants(:test_running_vacant, 600) == []
    end
  end

  describe "handle_forum_event/4" do
    test "inserts and deletes from ETS table" do
      table = :ets.new(:test_forum, [:set, :public])

      MetricsCleaner.handle_forum_event(
        [:forum, :users, :group, :vacant],
        %{},
        %{group: "test-tenant"},
        table
      )

      assert [{"test-tenant", _timestamp}] = :ets.lookup(table, "test-tenant")

      MetricsCleaner.handle_forum_event(
        [:forum, :users, :group, :occupied],
        %{},
        %{group: "test-tenant"},
        table
      )

      assert [] = :ets.lookup(table, "test-tenant")
    end
  end

  describe "handle_syn_event/4" do
    test "inserts and deletes from ETS table" do
      table = :ets.new(:test_syn, [:set, :public])

      MetricsCleaner.handle_syn_event(
        [:syn, Connect, :unregistered],
        %{},
        %{name: "test-tenant"},
        table
      )

      assert [{"test-tenant", _timestamp}] = :ets.lookup(table, "test-tenant")

      MetricsCleaner.handle_syn_event(
        [:syn, Connect, :registered],
        %{},
        %{name: "test-tenant"},
        table
      )

      assert [] = :ets.lookup(table, "test-tenant")
    end
  end

  defp exported?(tenant) do
    Realtime.TenantPromEx.get_metrics() |> IO.iodata_to_binary() |> String.contains?(~s(tenant="#{tenant}"))
  end
end
