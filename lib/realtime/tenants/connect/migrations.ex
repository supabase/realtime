defmodule Realtime.Tenants.Connect.Migrations do
  @moduledoc """
  Migrations for the Tenants.Connect process.
  """
  @behaviour Realtime.Tenants.Connect.Piper
  alias Realtime.Tenants.Migrations

  @impl true
  def run(%{db_conn_pid: db_conn_pid, tenant_id: tenant_id} = acc) do
    {:ok, _} = Migrations.maybe_run_migrations(db_conn_pid, tenant_id)
    {:ok, acc}
  end
end
