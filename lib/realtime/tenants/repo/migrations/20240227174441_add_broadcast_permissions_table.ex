defmodule Realtime.Tenants.Migrations.AddBroadcastsPermissionsTable do
  @moduledoc false

  use Ecto.Migration

  def change do
    create table(:broadcasts) do
      add :channel_id, references(:channels, on_delete: :delete_all)
      add :check, :boolean, default: false
      timestamps()
    end

    unique_index(:broadcasts, :channel_id)

    execute("ALTER TABLE realtime.broadcasts ENABLE row level security")
    execute("GRANT SELECT ON realtime.broadcasts TO postgres, anon, authenticated, service_role")
    execute("GRANT UPDATE ON realtime.broadcasts TO postgres, anon, authenticated, service_role")
  end
end
