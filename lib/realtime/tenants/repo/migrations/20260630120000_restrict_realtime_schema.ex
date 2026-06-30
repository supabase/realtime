defmodule Realtime.Tenants.Migrations.RestrictRealtimeSchema do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("ALTER TABLE realtime.messages OWNER TO supabase_realtime_admin")
    execute("ALTER TABLE realtime.subscription OWNER TO supabase_realtime_admin")
    execute("ALTER TYPE realtime.action OWNER TO supabase_realtime_admin")
    execute("ALTER TYPE realtime.equality_op OWNER TO supabase_realtime_admin")
    execute("ALTER TYPE realtime.user_defined_filter OWNER TO supabase_realtime_admin")
    execute("ALTER TYPE realtime.wal_column OWNER TO supabase_realtime_admin")
    execute("ALTER TYPE realtime.wal_rls OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.apply_rls(jsonb, integer) OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.list_changes(name, name, integer, integer) OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.quote_wal2json(regclass) OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.send(jsonb, text, text, boolean) OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.send_binary(bytea, text, text, boolean) OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.subscription_check_filters() OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.to_regrole(text) OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.topic() OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.wal2json_escape_identifier(text) OWNER TO supabase_realtime_admin")

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
      "ALTER FUNCTION realtime.check_equality_op(realtime.equality_op, regtype, text, text, boolean) OWNER TO supabase_realtime_admin"
    )

    execute(
      "ALTER FUNCTION realtime.is_visible_through_filters(realtime.wal_column[], realtime.user_defined_filter[]) OWNER TO supabase_realtime_admin"
    )

    execute("""
    DO $$
    DECLARE
      grants text := current_setting('supautils.policy_grants', true);
    BEGIN
      IF grants LIKE '%realtime.messages%' AND grants LIKE '%realtime.subscription%' THEN
        REVOKE supabase_realtime_admin FROM postgres;
        GRANT USAGE ON SCHEMA realtime TO postgres WITH GRANT OPTION;
        REVOKE CREATE ON SCHEMA realtime FROM postgres;
      END IF;
    END $$;
    """)

    execute("REVOKE ALL ON realtime.schema_migrations FROM postgres, dashboard_user, anon, authenticated, service_role")

    execute(
      "REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON realtime.schema_migrations FROM supabase_realtime_admin"
    )
  end
end
