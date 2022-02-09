defmodule Multiplayer.Repo.Migrations.CreateScopes do
  use Ecto.Migration

  def change do
    create table(:scopes, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:host, :string)
      add(:tenant_id, references(:tenants, on_delete: :nothing, type: :binary_id))

      timestamps()
    end

    create(index(:scopes, [:host]))
    create(unique_index(:scopes, [:tenant_id, :host]))
  end
end
