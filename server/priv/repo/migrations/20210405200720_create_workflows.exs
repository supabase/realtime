defmodule Realtime.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :name, :string
      add :trigger, :string
      add :default_execution_type, :string

      timestamps()
    end

    create unique_index(:workflows, [:name])

    create table(:revisions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :workflow_id, references(:workflows, type: :uuid, on_delete: :delete_all)
      add :version, :integer

      add :definition, :map

      timestamps()
    end

    create unique_index(:revisions, [:workflow_id, :version])

    create table(:executions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :revision_id, references(:revisions, type: :uuid, on_delete: :delete_all)

      add :arguments, :map
      add :execution_type, :string

      timestamps()
    end

    # Selects the latest revision for each workflow
    execute """
    create view latest_revisions as
    select distinct on (workflow_id) *
    from revisions
    order by workflow_id, version desc;
    """

  end
end
