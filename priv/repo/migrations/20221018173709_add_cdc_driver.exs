defmodule Realtime.Repo.Migrations.AddCdcDriver do
  use Ecto.Migration

  def up do
    alter table("tenants") do
      add(:postgres_cdc_driver, :string, default: "postgres_cdc_rls")
    end
  end

  def down do
    alter table("tenants") do
      remove(:postgres_cdc_driver)
    end
  end
end
