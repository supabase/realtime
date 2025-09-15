defmodule Realtime.Tenants.Connect.CheckConnection do
  @moduledoc """
  Check tenant database connection.
  """

  @behaviour Realtime.Tenants.Connect.Piper
  @impl true
  def run(acc) do
    %{tenant: tenant} = acc

    case Realtime.Database.check_tenant_connection(tenant) do
      {:ok, conn} ->
        db_conn_reference = Process.monitor(conn)
        {:ok, %{acc | db_conn_pid: conn, db_conn_reference: db_conn_reference}}

      {:error, error} ->
        {:error, error}
    end
  end
end
