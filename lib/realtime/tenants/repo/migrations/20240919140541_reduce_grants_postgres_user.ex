defmodule Realtime.Tenants.Migrations.ReduceGrantsPostgresUser do
  @moduledoc false
  use Ecto.Migration

  def change do
    execute("revoke supabase_realtime_admin from postgres")
    execute("alter default privileges for role supabase_admin in schema realtime revoke all on tables from postgres")
    execute("alter default privileges for role supabase_admin in schema realtime revoke all on functions from postgres")
    execute("alter default privileges for role supabase_admin in schema realtime revoke all on sequences from postgres")

    execute("revoke all on table realtime.schema_migrations from postgres, anon, authenticated, service_role")
    execute("grant select on table realtime.schema_migrations to postgres with grant option")

    execute("revoke all on table realtime.messages from postgres, anon, authenticated, service_role")
    execute("grant select, insert on table realtime.messages to postgres with grant option")

    execute("revoke all on table realtime.subscription from postgres")
    execute("grant select on table realtime.subscription to postgres with grant option")
  end
end
