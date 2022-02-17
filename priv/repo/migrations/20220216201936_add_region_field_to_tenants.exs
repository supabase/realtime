defmodule Multiplayer.Repo.Migrations.AddRegionFieldToTenants do
  use Ecto.Migration

  def up do
    alter table("tenants") do
      add(:region, :string)
    end
  end

  def down do
    alter table("tenants") do
      remove(:region)
    end
  end
end
