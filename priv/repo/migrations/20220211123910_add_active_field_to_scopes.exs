defmodule Multiplayer.Repo.Migrations.AddActiveFieldToScopes do
  use Ecto.Migration

  def up do
    alter table("scopes") do
      add :active, :boolean
    end
  end

  def down do
    alter table("scopes") do
      remove :active
    end
  end
end
