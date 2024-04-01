defmodule Realtime.Tenants.Migrations.CreateRealtimeAdminAndMoveOwnership do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("CREATE ROLE supabase_realtime_admin WITH NOINHERIT NOLOGIN NOREPLICATION")

    execute("GRANT ALL PRIVILEGES ON SCHEMA realtime TO supabase_realtime_admin")
    execute("GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA realtime TO supabase_realtime_admin")
    execute("GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA realtime TO supabase_realtime_admin")

    execute("ALTER table realtime.channels OWNER to supabase_realtime_admin")
    execute("ALTER table realtime.broadcasts OWNER to supabase_realtime_admin")
    execute("ALTER table realtime.presences OWNER TO supabase_realtime_admin")
    execute("ALTER function realtime.channel_name() owner to supabase_realtime_admin")

    execute("""
    DO
    $do$
    BEGIN
       IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles
          WHERE  rolname = 'authenticator') THEN
          CREATE ROLE authenticator NOINHERIT ;
          GRANT anon TO authenticator;
          GRANT authenticated TO authenticator;
          GRANT service_role TO authenticator;
          GRANT postgres TO authenticator;
       END IF;
    END
    $do$;
    """)

    execute("GRANT supabase_realtime_admin TO authenticator")
  end
end
