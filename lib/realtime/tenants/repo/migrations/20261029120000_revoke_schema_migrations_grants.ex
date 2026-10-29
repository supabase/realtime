defmodule Realtime.Tenants.Migrations.RevokeSchemaMigrationsGrants do
  @moduledoc false

  use Ecto.Migration

  def up do
    execute(
      "REVOKE ALL ON realtime.schema_migrations FROM postgres, dashboard_user, anon, authenticated, service_role, supabase_realtime_admin"
    )
  end

  def down do
    execute("GRANT ALL ON realtime.schema_migrations TO postgres, dashboard_user")
  end
end
