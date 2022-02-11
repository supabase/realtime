defmodule Multiplayer.Repo.Migrations.AddActiveFieldToTenants do
  use Ecto.Migration

  def up do
    alter table("tenants") do
      add :active, :boolean
    end
  end

  def down do
    alter table("tenants") do
      remove :active
    end
  end
end
