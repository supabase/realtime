defmodule Realtime.Tenants.Connect.StartReplication do
  @moduledoc """
  Starts BroadcastChanges replication slot.
  """

  @behaviour Realtime.Tenants.Connect.Piper
  alias Realtime.BroadcastChanges.Handler

  @impl true
  def run(acc) do
    %{tenant: tenant} = acc

    if tenant.notify_private_alpha do
      opts = %Handler{tenant_id: tenant.external_id}
      supervisor_spec = Handler.supervisor_spec(tenant)

      child_spec = %{
        id: Handler,
        start: {Handler, :start_link, [opts]},
        restart: :transient,
        type: :worker
      }

      case DynamicSupervisor.start_child(supervisor_spec, child_spec) do
        {:ok, pid} -> {:ok, Map.put(acc, :broadcast_changes_pid, pid)}
        {:error, {:already_started, pid}} -> {:ok, Map.put(acc, :broadcast_changes_pid, pid)}
        error -> {:error, error}
      end
    else
      {:ok, acc}
    end
  end
end
