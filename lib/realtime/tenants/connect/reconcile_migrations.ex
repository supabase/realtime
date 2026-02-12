defmodule Realtime.Tenants.Connect.ReconcileMigrations do
  @moduledoc """
  Reconciles the tenant's cached migrations_ran counter with the actual
  migration count from the tenant database's schema_migrations table.

  This handles the case where a project restore causes the database schema
  to revert while the migrations_ran counter remains at the latest value.
  """

  use Realtime.Logs

  alias Realtime.Api

  @behaviour Realtime.Tenants.Connect.Piper

  @impl true
  def run(%{tenant: tenant, migrations_ran_on_database: migrations_ran_on_database} = acc) do
    if tenant.migrations_ran != migrations_ran_on_database do
      log_warning(
        "MigrationCountMismatch",
        "cached=#{tenant.migrations_ran} database=#{migrations_ran_on_database}"
      )

      case Api.update_migrations_ran(tenant.external_id, migrations_ran_on_database) do
        {:ok, updated_tenant} -> {:ok, %{acc | tenant: updated_tenant}}
        {:error, error} -> {:error, error}
      end
    else
      {:ok, acc}
    end
  end
end
