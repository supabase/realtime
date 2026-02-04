defmodule Realtime.Tenants.ReplicationConnection.WatchdogTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Realtime.Tenants.ReplicationConnection.Watchdog

  defmodule FakeReplicationConnection do
    def child_spec(opts) do
      %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker, restart: :temporary, shutdown: 500}
    end

    def start_link(opts \\ []), do: :gen_statem.start_link(__MODULE__, opts, [])

    def callback_mode, do: :state_functions

    def init(opts) do
      respond_to_health_checks = Keyword.get(opts, :respond_to_health_checks, true)
      delay_ms = Keyword.get(opts, :delay_ms, 0)

      data = %{
        respond_to_health_checks: respond_to_health_checks,
        delay_ms: delay_ms,
        health_check_count: 0
      }

      {:ok, :idle, data}
    end

    def idle({:call, from}, :health_check, %{respond_to_health_checks: true, delay_ms: delay_ms} = data) do
      if delay_ms > 0 do
        Process.sleep(delay_ms)
      end

      :gen_statem.reply(from, :ok)
      {:keep_state, %{data | health_check_count: data.health_check_count + 1}}
    end

    def idle({:call, _from}, :health_check, %{respond_to_health_checks: false} = data) do
      # Don't reply - this will cause a timeout
      {:keep_state, %{data | health_check_count: data.health_check_count + 1}}
    end

    def idle({:call, from}, :get_health_check_count, data) do
      :gen_statem.reply(from, data.health_check_count)
      {:keep_state, data}
    end

    def idle({:call, from}, :set_no_respond, data) do
      :gen_statem.reply(from, :ok)
      {:keep_state, %{data | respond_to_health_checks: false}}
    end

    def get_health_check_count(pid), do: :gen_statem.call(pid, :get_health_check_count)

    def set_no_respond(pid), do: :gen_statem.call(pid, :set_no_respond)
  end

  test "performs periodic health checks successfully" do
    fake_pid = start_link_supervised!(FakeReplicationConnection)

    watchdog_pid =
      start_supervised!(
        {Watchdog, parent_pid: fake_pid, tenant_id: "test-tenant", watchdog_interval: 50, watchdog_timeout: 100}
      )

    # Wait for at least 2 health check cycles
    Process.sleep(150)

    assert Process.alive?(watchdog_pid)
    assert Process.alive?(fake_pid)

    # Verify health checks were performed
    count = FakeReplicationConnection.get_health_check_count(fake_pid)
    assert count >= 2
  end

  describe "timeout handling" do
    test "stops when health check times out" do
      # Create a fake process that doesn't respond to health checks
      fake_pid = start_supervised!({FakeReplicationConnection, respond_to_health_checks: false})

      logs =
        capture_log(fn ->
          watchdog_pid =
            start_supervised!(
              {Watchdog, parent_pid: fake_pid, tenant_id: "test-tenant", watchdog_interval: 50, watchdog_timeout: 100}
            )

          ref = Process.monitor(watchdog_pid)

          # Wait for the first health check to timeout
          assert_receive {:DOWN, ^ref, :process, ^watchdog_pid, :watchdog_timeout}, 200
          refute Process.alive?(watchdog_pid)
        end)

      assert logs =~ "ReplicationConnectionWatchdogTimeout"
      assert logs =~ "ReplicationConnection is not responding"
    end

    test "stops immediately if health check takes longer than timeout" do
      # Create a fake process with a 200ms delay
      fake_pid = start_supervised!({FakeReplicationConnection, delay_ms: 200})

      logs =
        capture_log(fn ->
          watchdog_pid =
            start_supervised!(
              {Watchdog, parent_pid: fake_pid, tenant_id: "timeout-test", watchdog_interval: 50, watchdog_timeout: 100}
            )

          ref = Process.monitor(watchdog_pid)

          # Should timeout because delay (200ms) > timeout (100ms)
          assert_receive {:DOWN, ^ref, :process, ^watchdog_pid, :watchdog_timeout}, 300
        end)

      assert logs =~ "ReplicationConnectionWatchdogTimeout"
    end
  end

  describe "dynamic behavior changes" do
    test "handles transition from healthy to timeout" do
      # Start with responding, then stop responding
      fake_pid = start_supervised!(FakeReplicationConnection)

      watchdog_pid =
        start_supervised!(
          {Watchdog, parent_pid: fake_pid, tenant_id: "test-tenant", watchdog_interval: 50, watchdog_timeout: 100}
        )

      # Wait for first successful health check
      Process.sleep(80)
      assert Process.alive?(watchdog_pid)

      ref = Process.monitor(watchdog_pid)
      # Now make the fake process stop responding
      FakeReplicationConnection.set_no_respond(fake_pid)

      logs =
        capture_log(fn ->
          # Should timeout on next health check
          assert_receive {:DOWN, ^ref, :process, ^watchdog_pid, :watchdog_timeout}, 200
        end)

      assert logs =~ "ReplicationConnectionWatchdogTimeout"
    end
  end
end
