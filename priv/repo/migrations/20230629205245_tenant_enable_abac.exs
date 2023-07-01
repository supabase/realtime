defmodule Realtime.Repo.Migrations.TenantEnableAbac do
  use Ecto.Migration

  def change do
    alter table("tenants") do
      add(:enable_abac, :boolean, default: false, null: false)
    end
  end
end
