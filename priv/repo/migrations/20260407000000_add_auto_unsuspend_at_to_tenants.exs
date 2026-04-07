defmodule Realtime.Repo.Migrations.AddAutoUnsuspendAtToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :auto_unsuspend_at, :utc_datetime_usec, null: true, default: nil
    end
  end
end
