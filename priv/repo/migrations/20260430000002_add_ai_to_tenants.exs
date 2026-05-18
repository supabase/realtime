defmodule Realtime.Repo.Migrations.AddAiToTenants do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :ai_enabled, :boolean, default: false, null: false
      add :max_ai_events_per_second, :integer, default: 100, null: false
      add :max_ai_tokens_per_minute, :integer, default: 60_000, null: false
    end
  end
end
