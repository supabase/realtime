defmodule Realtime.Repo.Migrations.NullableJwtSecrets do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      modify :jwt_secret, :string, null: true
    end
  end
end
