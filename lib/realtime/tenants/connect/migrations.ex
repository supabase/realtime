defmodule Realtime.Tenants.Connect.Migrations do
  @moduledoc """
  Migrations for the Tenants.Connect process.
  """
  @behaviour Realtime.Tenants.Connect.Piper
  alias Realtime.Tenants.Migrations
  alias Realtime.Tenants.Cache
  @impl true
  def run(acc) do
    %{tenant_id: tenant_id} = acc
    tenant = Cache.get_tenant_by_external_id(tenant_id)
    [%{settings: settings} | _] = tenant.extensions
    migrations = %Migrations{tenant_external_id: tenant.external_id, settings: settings}

    case Migrations.run_migrations(migrations) do
      :ok -> {:ok, acc}
      {:error, error} -> {:error, error}
    end
  end
end
