defmodule Realtime.Tenants.Connect.Migrations do
  @moduledoc """
  Migrations for the Tenants.Connect process.
  """
  @behaviour Realtime.Tenants.Connect.Piper
  alias Realtime.Tenants.Migrations

  @impl true
  def run(%{tenant: tenant} = acc) do
    # [%{settings: settings} | _] = tenant.extensions
    # migrations = %Migrations{tenant_external_id: tenant.external_id, settings: settings}

    # case Migrations.run_migrations(migrations) do
    #   :ok -> {:ok, acc}
    #   {:error, error} -> {:error, error}
    # end
    {:ok, acc}
  end
end
