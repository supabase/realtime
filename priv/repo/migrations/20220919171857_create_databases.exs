defmodule Realtime.Repo.Migrations.CreateDatabases do
  use Ecto.Migration

  def change do
    create table(:databases) do
      add :name, :string

      timestamps()
    end
  end
end
