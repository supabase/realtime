defmodule Realtime.Repo.Migrations.AddLastActiveAt do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add(:last_active_at, :naive_datetime)
    end
  end
end
