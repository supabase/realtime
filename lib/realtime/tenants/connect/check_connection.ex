defmodule Realtime.Tenants.Connect.CheckConnection do
  @moduledoc """
  Check tenant database connection.
  """
  alias Realtime.Database
  alias Realtime.Tenants.Cache

  @application_name "realtime_connect"
  @behaviour Realtime.Tenants.Connect.Piper
  @impl true
  def run(acc) do
    %{tenant_id: tenant_id} = acc
    tenant = Cache.get_tenant_by_external_id(tenant_id)

    case Database.check_tenant_connection(tenant, @application_name) do
      {:ok, conn} ->
        {:ok, %{acc | db_conn_pid: conn, db_conn_reference: Process.monitor(conn)}}

      {:error, error} ->
        {:error, error}
    end
  end
end
