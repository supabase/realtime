defmodule Realtime.Repo.Migrations.CreateTenants do
  use Ecto.Migration
  require Logger

  def change do
    Logger.info("Starting migration to create tenants table in realtime schema")

    # Ensure the schema exists (optional, for robustness)
    execute("CREATE SCHEMA IF NOT EXISTS realtime")

    # Set search path temporarily to ensure correct schema
    execute("SET search_path TO realtime")

    # Create the table
    create table(:tenants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string
      add :external_id, :string
      add :jwt_secret, :string, size: 500
      add :max_concurrent_users, :integer, default: 10_000
      timestamps(type: :utc_datetime_usec)
    end

    Logger.info("Created tenants table, creating index")

    # Create the index
    execute("CREATE UNIQUE INDEX tenants_external_id_index ON realtime.tenants (external_id);")

    Logger.info("Created tenants_external_id_index")
  end
end
