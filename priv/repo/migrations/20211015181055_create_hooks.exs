defmodule Multiplayer.Repo.Migrations.CreateHooks do
  use Ecto.Migration

  def change do
    create table(:hooks, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:type, :string)
      add(:event, :string)
      add(:url, :string)
      add(:tenant_id, references(:tenants, on_delete: :nothing, type: :binary_id))

      timestamps()
    end

    create(unique_index(:hooks, [:tenant_id, :type, :event]))
  end
end
