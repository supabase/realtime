defmodule Multiplayer.Repo.Migrations.AddEwalrusMaxChangesAndSizeLimits do
  use Ecto.Migration

  def up do
    alter table("tenants") do
      add(:rls_poll_max_changes, :integer, default: 100)
      add(:rls_poll_max_record_bytes, :integer, default: 1_048_576)
    end
  end

  def down do
    alter table("tenants") do
      remove(:rls_poll_max_changes)
      remove(:rls_poll_max_record_bytes)
    end
  end
end
