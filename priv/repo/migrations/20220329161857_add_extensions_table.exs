defmodule Realtime.Repo.Migrations.AddExtensionsTable do
  use Ecto.Migration

  def change do
    create table(:extensions, primary_key: false, prefix: "_realtime") do
      add(:id, :binary_id, primary_key: true)
      add(:type, :string)
      add(:settings, :map)

      add(
        :tenant_external_id,
        references(:tenants, on_delete: :delete_all, type: :string, column: :external_id, prefix: "_realtime")
      )

      timestamps()
    end

    create(index(:extensions, [:tenant_external_id, :type], unique: true, prefix: "_realtime"))
  end
end
