defmodule Realtime.Tenants.Migrations.IncreaseRealtimeMessagesTsResolution do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("""
    CREATE TABLE realtime.messages_v2 (
      topic        text NOT NULL,
      extension    text NOT NULL,
      payload      jsonb,
      event        text,
      private      boolean NOT NULL DEFAULT false,
      updated_at   timestamp(6) NOT NULL DEFAULT now(),
      inserted_at  timestamp(6) NOT NULL DEFAULT now(),
      id           uuid NOT NULL DEFAULT gen_random_uuid(),
      CONSTRAINT messages_v2_pkey PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at)
    """)

    execute("""
    CREATE INDEX messages_v2_inserted_at_topic_index
      ON ONLY realtime.messages_v2 (inserted_at DESC, topic)
      WHERE (extension = 'broadcast' AND private IS TRUE)
    """)

    execute("""
    DO $$
    DECLARE
      r RECORD;
      child_fq   text;
      bound_expr text;
    BEGIN
      FOR r IN
        SELECT
          c.oid                              AS child_oid,
          n.nspname                          AS child_schema,
          c.relname                          AS child_name,
          pg_get_expr(c.relpartbound, c.oid) AS bound_expr
        FROM pg_inherits i
        JOIN pg_class   c ON c.oid = i.inhrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_class   p ON p.oid = i.inhparent
        WHERE n.nspname='realtime' AND p.relname='messages'
        ORDER BY c.relname
      LOOP
        child_fq   := quote_ident(r.child_schema)||'.'||quote_ident(r.child_name);
        bound_expr := r.bound_expr;

        -- Detach from the old parent
        EXECUTE format('ALTER TABLE realtime.messages DETACH PARTITION %s', child_fq);

        -- Convert child timestamps to timestamptz(6); treat existing values as UTC
        EXECUTE format(
          'ALTER TABLE %s
             ALTER COLUMN inserted_at TYPE timestamptz(6) USING timezone(''UTC'', inserted_at),
             ALTER COLUMN updated_at  TYPE timestamptz(6) USING timezone(''UTC'', updated_at)',
          child_fq
        );

        -- Ensure defaults are sane on children (optional but tidy)
        EXECUTE format(
          'ALTER TABLE %s
             ALTER COLUMN inserted_at SET DEFAULT now(),
             ALTER COLUMN updated_at  SET DEFAULT now()',
          child_fq
        );

        -- Attach to the new parent with the original bounds
        IF bound_expr IS NULL THEN
          RAISE EXCEPTION 'Partition % has NULL relpartbound. Handle default partition explicitly.', child_fq;
        ELSIF bound_expr = 'DEFAULT' THEN
          EXECUTE format('ALTER TABLE realtime.messages_v2 ATTACH PARTITION %s DEFAULT', child_fq);
        ELSE
          EXECUTE format('ALTER TABLE realtime.messages_v2 ATTACH PARTITION %s %s', child_fq, bound_expr);
        END IF;
      END LOOP;
    END
    $$;
    """)

    execute("ALTER TABLE realtime.messages RENAME TO messages_old")
    execute("ALTER TABLE realtime.messages_v2 RENAME TO messages")

    execute("""
    DO $$
    DECLARE v_enable boolean; v_force boolean;
    BEGIN
      SELECT c.relrowsecurity, c.relforcerowsecurity
        INTO v_enable, v_force
      FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='realtime' AND c.relname='messages_old';

      IF v_enable THEN
        EXECUTE 'ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY';
      ELSE
        EXECUTE 'ALTER TABLE realtime.messages DISABLE ROW LEVEL SECURITY';
      END IF;

      IF v_force THEN
        EXECUTE 'ALTER TABLE realtime.messages FORCE ROW LEVEL SECURITY';
      ELSE
        EXECUTE 'ALTER TABLE realtime.messages NO FORCE ROW LEVEL SECURITY';
      END IF;
    END
    $$;
    """)

    execute("""
    DO $pol$
    DECLARE
      r record; roles_sql text; cmd_sql text; perm_sql text; using_sql text; check_sql text;
      exists_policy boolean; create_sql text;
    BEGIN
      FOR r IN
        SELECT p.policyname, p.permissive, p.cmd, p.roles, p.qual, p.with_check
        FROM pg_policies p
        WHERE p.schemaname='realtime' AND p.tablename='messages_old'
        ORDER BY p.policyname
      LOOP
        IF r.roles IS NULL THEN roles_sql := 'PUBLIC';
        ELSE
          SELECT string_agg(quote_ident(x), ', ') INTO roles_sql FROM unnest(r.roles) AS t(x);
        END IF;

        cmd_sql  := 'FOR '||r.cmd;
        perm_sql := CASE WHEN r.permissive THEN 'AS PERMISSIVE' ELSE 'AS RESTRICTIVE' END;
        using_sql := CASE WHEN r.qual IS NULL THEN '' ELSE ' USING ('||r.qual||')' END;
        check_sql := CASE WHEN r.with_check IS NULL THEN '' ELSE ' WITH CHECK ('||r.with_check||')' END;

        SELECT EXISTS(
          SELECT 1 FROM pg_policies
          WHERE schemaname='realtime' AND tablename='messages' AND policyname=r.policyname
        ) INTO exists_policy;

        IF NOT exists_policy THEN
          create_sql := format(
            'CREATE POLICY %I ON realtime.messages %s %s TO %s%s%s',
            r.policyname, perm_sql, cmd_sql, roles_sql, using_sql, check_sql
          );
          EXECUTE create_sql;
        END IF;
      END LOOP;
    END
    $pol$;
    """)

    execute("""
    DO $$
    DECLARE
      r record;
      idxdef text;
      newdef text;
      newname text;
    BEGIN
      FOR r IN
        SELECT i.indexname, i.indexdef
        FROM pg_indexes i
        WHERE i.schemaname='realtime' AND i.tablename='messages_old'
        ORDER BY i.indexname
      LOOP
        newname := r.indexname;
        IF position('messages_old' in newname) = 0 THEN
          newname := 'migr_'||newname;
        ELSE
          newname := replace(newname, 'messages_old', 'messages');
        END IF;

        idxdef := r.indexdef;

        -- Target ONLY realtime.messages just like your original layout
        newdef := regexp_replace(idxdef,
                  'ON\\s+ONLY\\s+realtime\\.messages_old',
                  'ON ONLY realtime.messages', 'i');
        newdef := regexp_replace(newdef,
                  'ON\\s+realtime\\.messages_old',
                  'ON ONLY realtime.messages', 'i');

        -- Replace index name at the start
        newdef := regexp_replace(newdef,
                  '^CREATE\\s+(UNIQUE\\s+)?INDEX\\s+\\S+',
                  CASE WHEN position('UNIQUE' in upper(newdef))>0
                    THEN 'CREATE UNIQUE INDEX '||quote_ident(newname)
                    ELSE 'CREATE INDEX '||quote_ident(newname)
                  END,
                  'i');

        EXECUTE newdef;
      END LOOP;
    END
    $$;
    """)

    execute("""
    DO $$
    DECLARE
      r record;
      newdef text;
    BEGIN
      FOR r IN
        SELECT tg.tgname, pg_get_triggerdef(tg.oid, true) AS def
        FROM pg_trigger tg
        JOIN pg_class c ON c.oid = tg.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'realtime'
          AND c.relname = 'messages_old'
          AND tg.tgisinternal = false
      LOOP
        -- Repoint trigger definition to the new parent
        newdef := replace(r.def, ' ON ONLY realtime.messages_old ', ' ON ONLY realtime.messages ');
        newdef := replace(newdef, ' ON realtime.messages_old ', ' ON realtime.messages ');

        -- Drop a same-named trigger on the target if it exists
        IF EXISTS (
          SELECT 1
          FROM pg_trigger t
          JOIN pg_class c2 ON c2.oid = t.tgrelid
          JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
          WHERE n2.nspname = 'realtime'
            AND c2.relname = 'messages'
            AND t.tgname = r.tgname
        ) THEN
          EXECUTE format('DROP TRIGGER %I ON realtime.messages', r.tgname);
        END IF;

        -- Create the trigger on the new parent
        EXECUTE newdef;
      END LOOP;
    END
    $$;
    """)

    execute("""
    DO $$
    DECLARE
      r record;
      priv text;
      grantable boolean;
      grantee text;
      obj_owner text;
    BEGIN
      SELECT pg_get_userbyid(c.relowner)
        INTO obj_owner
      FROM pg_class c
      JOIN pg_namespace n ON n.oid=c.relnamespace
      WHERE n.nspname='realtime' AND c.relname='messages_old';

      EXECUTE 'REVOKE ALL ON TABLE realtime.messages FROM PUBLIC';
      EXECUTE format('REVOKE ALL ON TABLE realtime.messages FROM %I', obj_owner);

      FOR r IN
        SELECT (aclexplode(c.relacl)).*
        FROM pg_class c
        JOIN pg_namespace n ON n.oid=c.relnamespace
        WHERE n.nspname='realtime' AND c.relname='messages_old'
          AND c.relacl IS NOT NULL
      LOOP
        grantee := CASE WHEN r.grantee = 0 THEN 'PUBLIC' ELSE pg_get_userbyid(r.grantee) END;

        FOREACH priv IN ARRAY string_to_array(
          translate(r.privilege_type::text,'{}',''), ','
        )
        LOOP
          grantable := r.is_grantable;
          EXECUTE format(
            'GRANT %s ON TABLE realtime.messages TO %s%s',
            priv,
            CASE WHEN grantee='PUBLIC' THEN 'PUBLIC' ELSE quote_ident(grantee) END,
            CASE WHEN grantable THEN ' WITH GRANT OPTION' ELSE '' END
          );
        END LOOP;
      END LOOP;
    END
    $$;
    """)

    execute("""
    DROP TABLE realtime.messages_old
    """)
  end
end
