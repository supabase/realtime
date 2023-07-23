defmodule Realtime.Repo.Migrations.AddSigningMethod do
  use Ecto.Migration

  def change do
    alter table("tenants") do
      modify(:jwt_secret, :string, size: 5000)
      add(:jwt_signing_method, :string, size: 500)
    end
  end

end
