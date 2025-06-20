defmodule RealtimeWeb.SocketDisconnect do
  @moduledoc """
  Handles the distributed disconnection of sockets for a given tenant. It also ensures that there are no repeated registrations of the same transport PID for a given tenant.
  """
  use Realtime.Logs

  alias Phoenix.Socket
  alias Realtime.Api.Tenant
  alias Realtime.Tenants

  @doc """
  Adds a socket to the registry associated to a tenant.
  It will register the transport PID and a list of channel PIDs associated with a given transport pid.
  """
  @spec add(binary(), Socket.t()) :: :ok | {:error, term()}
  def add(tenant_external_id, %Socket{transport_pid: transport_pid}) when is_binary(tenant_external_id) do
    transport_pid_exists_match_spec = [
      {
        {tenant_external_id, :"$1", :"$2"},
        [{:==, :"$2", transport_pid}],
        [:"$1"]
      }
    ]

    case Registry.select(__MODULE__.Registry, transport_pid_exists_match_spec) do
      [] -> {:ok, _} = Registry.register(__MODULE__.Registry, tenant_external_id, transport_pid)
      _ -> nil
    end

    :ok
  end

  @doc """
  Disconnects all sockets associated with a given tenant across all nodes in the cluster.
  """
  @spec distributed_disconnect(Tenant.t() | binary()) :: list(:ok | :error)
  def distributed_disconnect(%Tenant{external_id: external_id}), do: distributed_disconnect(external_id)

  def distributed_disconnect(external_id) do
    [Node.self() | Node.list()]
    |> :erpc.multicall(__MODULE__, :disconnect, [external_id], 5000)
    |> Enum.map(fn {res, _} -> res end)
  end

  @doc """
  Disconnects all sockets associated with a given tenant on the current node.
  """
  @spec disconnect(binary()) :: :ok | :error
  def disconnect(%Tenant{external_id: external_id}), do: disconnect(external_id)

  def disconnect(tenant_external_id) do
    Logger.metadata(external_id: tenant_external_id, project: tenant_external_id)
    Logger.warning("Disconnecting all sockets for tenant #{tenant_external_id}")
    Tenants.broadcast_operation_event(:disconnect, tenant_external_id)

    pids = Registry.lookup(__MODULE__.Registry, tenant_external_id)
    for {_, pid} <- pids, Process.alive?(pid), do: Process.exit(pid, :shutdown)
    Registry.unregister(__MODULE__.Registry, tenant_external_id)

    :ok
  end
end
