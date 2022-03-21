defmodule Multiplayer.Repo.Migrations.AddMaxConcurrentUsers do
  use Ecto.Migration

  def up do
    alter table("tenants") do
      add(:max_concurrent_users, :integer, default: 10000)
    end
  end

  def down do
    alter table("tenants") do
      remove(:max_concurrent_users)
    end
  end
end
