defmodule Realtime.Tenants.Reconnector do
  @moduledoc """
  Reactively restarts a tenant's `Realtime.Tenants.Connect` process when it unregisters from
  `:syn` while this node still has locally-connected websocket clients for that tenant.

  `Connect` is started with `restart: :temporary`, so its supervisor never restarts it after
  a crash. Without this module, a tenant whose `Connect` process dies (crash, node move,
  database connection drop) never gets it back unless a client triggers a new join/broadcast.
  """

  use GenServer
  require Logger

  alias Realtime.UsersCounter
  alias Realtime.Tenants.Connect

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def handle_syn_event([:syn, Connect, :unregistered], _measurements, %{name: tenant_id}, pid) do
    send(pid, {:check_reconnect, tenant_id})
  end

  @impl true
  def init(_opts) do
    Logger.info("Starting Reconnector")

    :ok =
      :telemetry.attach(
        [self(), :reconnector],
        [:syn, Connect, :unregistered],
        &__MODULE__.handle_syn_event/4,
        self()
      )

    {:ok, %{}}
  end

  @impl true
  def terminate(_reason, _state) do
    :telemetry.detach([self(), :reconnector])
    :ok
  end

  @impl true
  def handle_info({:check_reconnect, tenant_id}, state) do
    if UsersCounter.tenant_users(tenant_id, node()) > 0 do
      Task.Supervisor.start_child(Realtime.TaskSupervisor, fn -> reconnect(tenant_id) end)
    end

    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp reconnect(tenant_id) do
    case Connect.lookup_or_start_connection(tenant_id) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Reconnector could not restart connection for #{tenant_id}: #{inspect(reason)}")
    end
  end
end
