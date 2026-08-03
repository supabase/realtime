defmodule Realtime.Repo.Migrations.AddGcmEncryptionColumns do
  use Ecto.Migration

  def up do
    alter table(:tenants) do
      add(:jwt_secret_gcm, :text)
    end

    drop constraint(:tenants, :jwt_secret_or_jwt_jwks_required)

    create constraint(:tenants, :jwt_secret_or_jwt_jwks_required,
             check: "jwt_secret IS NOT NULL OR jwt_secret_gcm IS NOT NULL OR jwt_jwks IS NOT NULL"
           )

    alter table(:extensions) do
      add(:settings_gcm, :map)
    end
  end

  def down do
    alter table(:extensions) do
      remove(:settings_gcm)
    end

    drop constraint(:tenants, :jwt_secret_or_jwt_jwks_required)

    create constraint(:tenants, :jwt_secret_or_jwt_jwks_required,
             check: "jwt_secret IS NOT NULL OR jwt_jwks IS NOT NULL"
           )

    alter table(:tenants) do
      remove(:jwt_secret_gcm)
    end
  end
end
