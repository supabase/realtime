defmodule Multiplayer.Repo.Migrations.CreateProjectScopes do
  use Ecto.Migration

  def change do
    create table(:project_scopes) do
      add :host, :string
      add :project_id, references(:projects, on_delete: :nothing)

      timestamps()
    end

    create index(:project_scopes, [:project_id])
  end
end
