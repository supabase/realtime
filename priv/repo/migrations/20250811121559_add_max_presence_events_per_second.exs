defmodule Realtime.Repo.Migrations.AddMaxPresenceEventsPerSecond do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :max_presence_events_per_second, :integer, default: 100
    end
  end
end
