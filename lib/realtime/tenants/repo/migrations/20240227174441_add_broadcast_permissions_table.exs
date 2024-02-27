defmodule Realtime.Repo.Migrations.AddBroadcastPermissionsTable do
  use Ecto.Migration

  def up do
    create table(:broadcast) do
      add :channel_id, references(:channels, on_delete: :delete_all)
      add :check, :boolean, default: false
      timestamps()
    end

    unique_index(:broadcast, :channel_id)
  end

  def down do
    drop table(:broadcast)
  end
end
