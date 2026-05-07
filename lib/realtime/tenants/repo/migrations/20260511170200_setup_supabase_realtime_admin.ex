defmodule Realtime.Tenants.Migrations.SetupSupabaseRealtimeAdmin do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("""
    DO $$
    BEGIN
      IF (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        ALTER ROLE supabase_realtime_admin WITH LOGIN REPLICATION;
        ALTER ROLE supabase_realtime_admin SET search_path = public, extensions, realtime;
        GRANT CREATE ON DATABASE postgres TO supabase_realtime_admin;
        GRANT SET ON PARAMETER log_min_messages TO supabase_realtime_admin;
        GRANT anon, authenticated, service_role TO supabase_realtime_admin;
        GRANT CREATE, USAGE ON SCHEMA public TO supabase_realtime_admin;
        GRANT USAGE ON SCHEMA extensions TO supabase_realtime_admin;
        GRANT USAGE ON SCHEMA auth TO supabase_realtime_admin;
        GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA auth TO supabase_realtime_admin;
        GRANT USAGE ON SCHEMA realtime TO postgres, anon, authenticated, service_role;
        GRANT ALL ON SCHEMA realtime TO supabase_realtime_admin WITH GRANT OPTION;
      END IF;
    END $$;
    """)

    execute("ALTER TABLE realtime.messages OWNER TO supabase_realtime_admin")
    execute("ALTER TABLE realtime.subscription OWNER TO supabase_realtime_admin")
    execute("ALTER TYPE realtime.action OWNER TO supabase_realtime_admin")
    execute("ALTER TYPE realtime.equality_op OWNER TO supabase_realtime_admin")
    execute("ALTER TYPE realtime.user_defined_filter OWNER TO supabase_realtime_admin")
    execute("ALTER TYPE realtime.wal_column OWNER TO supabase_realtime_admin")
    execute("ALTER TYPE realtime.wal_rls OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.apply_rls(jsonb, integer) OWNER TO supabase_realtime_admin")

    execute(
      "ALTER FUNCTION realtime.broadcast_changes(text, text, text, text, text, record, record, text) OWNER TO supabase_realtime_admin"
    )

    execute(
      "ALTER FUNCTION realtime.build_prepared_statement_sql(text, regclass, realtime.wal_column[]) OWNER TO supabase_realtime_admin"
    )

    execute("ALTER FUNCTION realtime.cast(text, regtype) OWNER TO supabase_realtime_admin")

    execute(
      "ALTER FUNCTION realtime.check_equality_op(realtime.equality_op, regtype, text, text) OWNER TO supabase_realtime_admin"
    )

    execute(
      "ALTER FUNCTION realtime.is_visible_through_filters(realtime.wal_column[], realtime.user_defined_filter[]) OWNER TO supabase_realtime_admin"
    )

    execute("ALTER FUNCTION realtime.list_changes(name, name, integer, integer) OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.quote_wal2json(regclass) OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.send(jsonb, text, text, boolean) OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.subscription_check_filters() OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.to_regrole(text) OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.topic() OWNER TO supabase_realtime_admin")

    execute("""
    DO $$
    BEGIN
      IF (SELECT rolsuper FROM pg_roles WHERE rolname = current_user) THEN
        REVOKE supabase_realtime_admin FROM postgres;
      END IF;
    END $$;
    """)

    execute("REVOKE CREATE ON SCHEMA realtime FROM postgres")
    execute("REVOKE ALL ON realtime.schema_migrations FROM anon, authenticated, service_role, postgres")
    execute("GRANT USAGE ON SCHEMA realtime TO postgres WITH GRANT OPTION")
  end
end
