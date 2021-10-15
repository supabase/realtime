defmodule Multiplayer.Repo.Migrations.CreateHooks do
  use Ecto.Migration

  def change do
    create table(:hooks) do
      add :type, :string
      add :event, :string
      add :url, :string
      add :project_id, references(:projects, on_delete: :nothing, type: :binary_id)

      timestamps()
    end

    create unique_index(:hooks, [:project_id, :tyep, :event])
  end
end
