defmodule Realtime.Repo.Migrations.AddTenantsMigrationsRanIndex do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index(:tenants, [:migrations_ran], concurrently: true)
  end
end
