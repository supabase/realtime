defmodule Realtime.Repo.Migrations.AddNameToExtensions do
  use Ecto.Migration

  def up do
    alter table(:extensions) do
      add_if_not_exists :name, :string
    end

    drop_if_exists unique_index(:extensions, [:tenant_external_id, :type])
    create_if_not_exists unique_index(:extensions, [:tenant_external_id, :type, :name])
  end

  def down do
    drop_if_exists unique_index(:extensions, [:tenant_external_id, :type, :name])
    create_if_not_exists unique_index(:extensions, [:tenant_external_id, :type])

    alter table(:extensions) do
      remove_if_exists :name, :string
    end
  end
end
