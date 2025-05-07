defmodule Realtime.Tenants.Connect.RegisterProcess do
  @moduledoc """
  Registers the database process in :syn
  """
  @behaviour Realtime.Tenants.Connect.Piper

  @impl true
  def run(acc) do
    %{tenant_id: tenant_id, db_conn_pid: conn} = acc

    case :syn.update_registry(Realtime.Tenants.Connect, tenant_id, fn _pid, meta -> %{meta | conn: conn} end) do
      {:ok, _} -> {:ok, acc}
      {:error, :undefined} -> {:error, :process_not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
