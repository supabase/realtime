defmodule Realtime.Repo.Migrations.SetDefaultPresenceValue do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true
  def change do
    alter table(:tenants) do
      modify :max_presence_events_per_second, :integer, default: 100
    end
  end
end
