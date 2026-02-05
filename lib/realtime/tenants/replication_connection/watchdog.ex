defmodule Realtime.Tenants.ReplicationConnection.Watchdog do
  @moduledoc """
  Monitors ReplicationConnection health by performing periodic call checks.
  If the call times out, logs an error and shuts down, which cascades to ReplicationConnection.
  """
  use GenServer
  use Realtime.Logs

  @default_check_interval :timer.minutes(5)
  @default_timeout :timer.minutes(1)

  defstruct [:parent_pid, :tenant_id, :check_interval, :timeout]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    parent_pid = Keyword.fetch!(opts, :parent_pid)
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    check_interval =
      Keyword.get(
        opts,
        :watchdog_interval,
        Application.get_env(:realtime, :replication_watchdog_interval, @default_check_interval)
      )

    timeout =
      Keyword.get(
        opts,
        :watchdog_timeout,
        Application.get_env(:realtime, :replication_watchdog_timeout, @default_timeout)
      )

    Logger.metadata(external_id: tenant_id, project: tenant_id)

    # Schedule first health check
    Process.send_after(self(), :health_check, check_interval)

    state = %__MODULE__{
      parent_pid: parent_pid,
      tenant_id: tenant_id,
      check_interval: check_interval,
      timeout: timeout
    }

    {:ok, state}
  end

  @impl true
  def handle_info(:health_check, state) do
    try do
      case Realtime.Tenants.ReplicationConnection.health_check(state.parent_pid, state.timeout) do
        :ok ->
          Process.send_after(self(), :health_check, state.check_interval)
          {:noreply, state}
      end
    catch
      :exit, {:timeout, _} ->
        log_error(
          "ReplicationConnectionWatchdogTimeout",
          "ReplicationConnection is not responding"
        )

        {:stop, :watchdog_timeout, state}
    end
  end
end
