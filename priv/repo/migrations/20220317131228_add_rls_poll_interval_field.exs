defmodule Multiplayer.Repo.Migrations.AddRlsPollIntervalField do
  use Ecto.Migration

  def up do
    alter table("tenants") do
      add(:rls_poll_interval, :integer, default: 100)
    end
  end

  def down do
    alter table("tenants") do
      remove(:rls_poll_interval)
    end
  end
end
