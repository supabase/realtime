defmodule Multiplayer.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :name, :string
      add :external_id, :string
      add :jwt_secret, :string

      timestamps()
    end

  end
end
