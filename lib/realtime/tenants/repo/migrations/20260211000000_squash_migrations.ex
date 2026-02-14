defmodule Realtime.Tenants.Migrations.SquashMigrations do
  @moduledoc false
  use Ecto.Migration

  def up do
    create_types()
    create_role()
    create_base_functions()
    create_tables()
    create_table_dependent_functions()
    create_indexes()
    create_trigger()
    configure_grants()
    configure_ownership()
    configure_rls()
  end

  def down, do: nil

  defp create_types do
    execute("""
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'action' AND typnamespace = 'realtime'::regnamespace) THEN
            CREATE TYPE realtime.action AS ENUM ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'ERROR');
        END IF;
    END$$;
    """)

    execute("""
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'equality_op' AND typnamespace = 'realtime'::regnamespace) THEN
            CREATE TYPE realtime.equality_op AS ENUM ('eq', 'neq', 'lt', 'lte', 'gt', 'gte', 'in');
        END IF;
    END$$;
    """)

    execute("""
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'user_defined_filter' AND typnamespace = 'realtime'::regnamespace) THEN
            CREATE TYPE realtime.user_defined_filter AS (
                column_name text,
                op realtime.equality_op,
                value text
            );
        END IF;
    END$$;
    """)

    execute("""
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'wal_column' AND typnamespace = 'realtime'::regnamespace) THEN
            CREATE TYPE realtime.wal_column AS (
                name text,
                type_name text,
                type_oid oid,
                value jsonb,
                is_pkey boolean,
                is_selectable boolean
            );
        END IF;
    END$$;
    """)

    execute("""
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'wal_rls' AND typnamespace = 'realtime'::regnamespace) THEN
            CREATE TYPE realtime.wal_rls AS (
                wal jsonb,
                is_rls_enabled boolean,
                subscription_ids uuid[],
                errors text[]
            );
        END IF;
    END$$;
    """)
  end

  defp create_role do
    execute("""
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'supabase_realtime_admin') THEN
            CREATE ROLE supabase_realtime_admin WITH NOINHERIT NOLOGIN NOREPLICATION;
        END IF;
    END$$;
    """)

    execute("GRANT supabase_realtime_admin TO postgres")
  end

  defp create_base_functions do
    execute("""
    CREATE OR REPLACE FUNCTION realtime.to_regrole(role_name text)
    RETURNS regrole
    LANGUAGE sql
    IMMUTABLE
    AS $func$ select role_name::regrole $func$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION realtime.topic()
    RETURNS text
    LANGUAGE sql
    STABLE
    AS $func$
    select nullif(current_setting('realtime.topic', true), '')::text;
    $func$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION realtime."cast"(val text, type_ regtype)
    RETURNS jsonb
    LANGUAGE plpgsql
    IMMUTABLE
    AS $func$
    declare
      res jsonb;
    begin
      execute format('select to_jsonb(%L::'|| type_::text || ')', val)  into res;
      return res;
    end
    $func$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION realtime.check_equality_op(
        op realtime.equality_op,
        type_ regtype,
        val_1 text,
        val_2 text
    )
    RETURNS boolean
    LANGUAGE plpgsql
    IMMUTABLE
    AS $func$
      declare
          op_symbol text = (
              case
                  when op = 'eq' then '='
                  when op = 'neq' then '!='
                  when op = 'lt' then '<'
                  when op = 'lte' then '<='
                  when op = 'gt' then '>'
                  when op = 'gte' then '>='
                  when op = 'in' then '= any'
                  else 'UNKNOWN OP'
              end
          );
          res boolean;
      begin
          execute format(
              'select %L::'|| type_::text || ' ' || op_symbol
              || ' ( %L::'
              || (
                  case
                      when op = 'in' then type_::text || '[]'
                      else type_::text end
              )
              || ')', val_1, val_2) into res;
          return res;
      end;
      $func$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION realtime.is_visible_through_filters(
        columns realtime.wal_column[],
        filters realtime.user_defined_filter[]
    )
    RETURNS boolean
    LANGUAGE sql
    IMMUTABLE
    AS $func$
        select
            $2 is null
            or array_length($2, 1) is null
            or bool_and(
                coalesce(
                    realtime.check_equality_op(
                        op:=f.op,
                        type_:=coalesce(
                            col.type_oid::regtype,
                            col.type_name::regtype
                        ),
                        val_1:=col.value #>> '{}',
                        val_2:=f.value
                    ),
                    false
                )
            )
        from
            unnest(filters) f
            join unnest(columns) col
                on f.column_name = col.name;
    $func$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION realtime.quote_wal2json(entity regclass)
    RETURNS text
    LANGUAGE sql
    IMMUTABLE STRICT
    AS $func$
      select
        (
          select string_agg('' || ch,'')
          from unnest(string_to_array(nsp.nspname::text, null)) with ordinality x(ch, idx)
          where
            not (x.idx = 1 and x.ch = '"')
            and not (
              x.idx = array_length(string_to_array(nsp.nspname::text, null), 1)
              and x.ch = '"'
            )
        )
        || '.'
        || (
          select string_agg('' || ch,'')
          from unnest(string_to_array(pc.relname::text, null)) with ordinality x(ch, idx)
          where
            not (x.idx = 1 and x.ch = '"')
            and not (
              x.idx = array_length(string_to_array(pc.relname::text, null), 1)
              and x.ch = '"'
            )
          )
      from
        pg_class pc
        join pg_namespace nsp
          on pc.relnamespace = nsp.oid
      where
        pc.oid = entity
    $func$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION realtime.build_prepared_statement_sql(
        prepared_statement_name text,
        entity regclass,
        columns realtime.wal_column[]
    )
    RETURNS text
    LANGUAGE sql
    AS $func$
          select
      'prepare ' || prepared_statement_name || ' as
          select
              exists(
                  select
                      1
                  from
                      ' || entity || '
                  where
                      ' || string_agg(quote_ident(pkc.name) || '=' || quote_nullable(pkc.value #>> '{}') , ' and ') || '
              )'
          from
              unnest(columns) pkc
          where
              pkc.is_pkey
          group by
              entity
      $func$;
    """)
  end

  defp create_tables do
    execute("""
    CREATE TABLE IF NOT EXISTS realtime.subscription (
        id bigint NOT NULL GENERATED ALWAYS AS IDENTITY,
        subscription_id uuid NOT NULL DEFAULT gen_random_uuid(),
        entity regclass NOT NULL,
        filters realtime.user_defined_filter[] NOT NULL DEFAULT '{}'::realtime.user_defined_filter[],
        claims jsonb NOT NULL,
        claims_role regrole NOT NULL GENERATED ALWAYS AS (realtime.to_regrole((claims ->> 'role'::text))) STORED,
        created_at timestamp without time zone NOT NULL DEFAULT timezone('utc'::text, now()),
        action_filter text DEFAULT '*'::text,
        CONSTRAINT pk_subscription PRIMARY KEY (id),
        CONSTRAINT subscription_action_filter_check CHECK ((action_filter = ANY (ARRAY['*'::text, 'INSERT'::text, 'UPDATE'::text, 'DELETE'::text])))
    )
    """)

    execute("""
    CREATE TABLE IF NOT EXISTS realtime.messages (
        topic text NOT NULL,
        extension text NOT NULL,
        payload jsonb,
        event text,
        private boolean DEFAULT false,
        updated_at timestamp without time zone DEFAULT now() NOT NULL,
        inserted_at timestamp without time zone DEFAULT now() NOT NULL,
        id uuid DEFAULT gen_random_uuid() NOT NULL,
        PRIMARY KEY (id, inserted_at)
    ) PARTITION BY RANGE (inserted_at)
    """)
  end

  defp create_table_dependent_functions do
    execute("""
    CREATE OR REPLACE FUNCTION realtime.subscription_check_filters()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $func$
    declare
        col_names text[] = coalesce(
                array_agg(c.column_name order by c.ordinal_position),
                '{}'::text[]
            )
            from
                information_schema.columns c
            where
                format('%I.%I', c.table_schema, c.table_name)::regclass = new.entity
                and pg_catalog.has_column_privilege(
                    (new.claims ->> 'role'),
                    format('%I.%I', c.table_schema, c.table_name)::regclass,
                    c.column_name,
                    'SELECT'
                );
        filter realtime.user_defined_filter;
        col_type regtype;

        in_val jsonb;
    begin
        for filter in select * from unnest(new.filters) loop
            if not filter.column_name = any(col_names) then
                raise exception 'invalid column for filter %', filter.column_name;
            end if;

            col_type = (
                select atttypid::regtype
                from pg_catalog.pg_attribute
                where attrelid = new.entity
                      and attname = filter.column_name
            );
            if col_type is null then
                raise exception 'failed to lookup type for column %', filter.column_name;
            end if;

            if filter.op = 'in'::realtime.equality_op then
                in_val = realtime.cast(filter.value, (col_type::text || '[]')::regtype);
                if coalesce(jsonb_array_length(in_val), 0) > 100 then
                    raise exception 'too many values for `in` filter. Maximum 100';
                end if;
            else
                perform realtime.cast(filter.value, col_type);
            end if;

        end loop;

        new.filters = coalesce(
            array_agg(f order by f.column_name, f.op, f.value),
            '{}'
        ) from unnest(new.filters) f;

        return new;
    end;
    $func$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION realtime.apply_rls(wal jsonb, max_record_bytes integer DEFAULT (1024 * 1024))
    RETURNS SETOF realtime.wal_rls
    LANGUAGE plpgsql
    AS $func$
    declare
    entity_ regclass = (quote_ident(wal ->> 'schema') || '.' || quote_ident(wal ->> 'table'))::regclass;

    action realtime.action = (
        case wal ->> 'action'
            when 'I' then 'INSERT'
            when 'U' then 'UPDATE'
            when 'D' then 'DELETE'
            else 'ERROR'
        end
    );

    is_rls_enabled bool = relrowsecurity from pg_class where oid = entity_;

    subscriptions realtime.subscription[] = array_agg(subs)
        from
            realtime.subscription subs
        where
            subs.entity = entity_
            and (subs.action_filter = '*' or subs.action_filter = action::text);

    roles regrole[] = array_agg(distinct us.claims_role::text)
        from
            unnest(subscriptions) us;

    working_role regrole;
    claimed_role regrole;
    claims jsonb;

    subscription_id uuid;
    subscription_has_access bool;
    visible_to_subscription_ids uuid[] = '{}';

    columns realtime.wal_column[];
    old_columns realtime.wal_column[];

    error_record_exceeds_max_size boolean = octet_length(wal::text) > max_record_bytes;

    output jsonb;

    begin
    perform set_config('role', null, true);

    columns =
        array_agg(
            (
                x->>'name',
                x->>'type',
                x->>'typeoid',
                realtime.cast(
                    (x->'value') #>> '{}',
                    coalesce(
                        (x->>'typeoid')::regtype,
                        (x->>'type')::regtype
                    )
                ),
                (pks ->> 'name') is not null,
                true
            )::realtime.wal_column
        )
        from
            jsonb_array_elements(wal -> 'columns') x
            left join jsonb_array_elements(wal -> 'pk') pks
                on (x ->> 'name') = (pks ->> 'name');

    old_columns =
        array_agg(
            (
                x->>'name',
                x->>'type',
                x->>'typeoid',
                realtime.cast(
                    (x->'value') #>> '{}',
                    coalesce(
                        (x->>'typeoid')::regtype,
                        (x->>'type')::regtype
                    )
                ),
                (pks ->> 'name') is not null,
                true
            )::realtime.wal_column
        )
        from
            jsonb_array_elements(wal -> 'identity') x
            left join jsonb_array_elements(wal -> 'pk') pks
                on (x ->> 'name') = (pks ->> 'name');

    for working_role in select * from unnest(roles) loop

        columns =
            array_agg(
                (
                    c.name,
                    c.type_name,
                    c.type_oid,
                    c.value,
                    c.is_pkey,
                    pg_catalog.has_column_privilege(working_role, entity_, c.name, 'SELECT')
                )::realtime.wal_column
            )
            from
                unnest(columns) c;

        old_columns =
                array_agg(
                    (
                        c.name,
                        c.type_name,
                        c.type_oid,
                        c.value,
                        c.is_pkey,
                        pg_catalog.has_column_privilege(working_role, entity_, c.name, 'SELECT')
                    )::realtime.wal_column
                )
                from
                    unnest(old_columns) c;

        if action <> 'DELETE' and count(1) = 0 from unnest(columns) c where c.is_pkey then
            return next (
                jsonb_build_object(
                    'schema', wal ->> 'schema',
                    'table', wal ->> 'table',
                    'type', action
                ),
                is_rls_enabled,
                (select array_agg(s.subscription_id) from unnest(subscriptions) as s where claims_role = working_role),
                array['Error 400: Bad Request, no primary key']
            )::realtime.wal_rls;

        elsif action <> 'DELETE' and sum(c.is_selectable::int) <> count(1) from unnest(columns) c where c.is_pkey then
            return next (
                jsonb_build_object(
                    'schema', wal ->> 'schema',
                    'table', wal ->> 'table',
                    'type', action
                ),
                is_rls_enabled,
                (select array_agg(s.subscription_id) from unnest(subscriptions) as s where claims_role = working_role),
                array['Error 401: Unauthorized']
            )::realtime.wal_rls;

        else
            output = jsonb_build_object(
                'schema', wal ->> 'schema',
                'table', wal ->> 'table',
                'type', action,
                'commit_timestamp', to_char(
                    ((wal ->> 'timestamp')::timestamptz at time zone 'utc'),
                    'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
                ),
                'columns', (
                    select
                        jsonb_agg(
                            jsonb_build_object(
                                'name', pa.attname,
                                'type', pt.typname
                            )
                            order by pa.attnum asc
                        )
                    from
                        pg_attribute pa
                        join pg_type pt
                            on pa.atttypid = pt.oid
                    where
                        attrelid = entity_
                        and attnum > 0
                        and pg_catalog.has_column_privilege(working_role, entity_, pa.attname, 'SELECT')
                )
            )
            || case
                when action in ('INSERT', 'UPDATE') then
                    jsonb_build_object(
                        'record',
                        (
                            select
                                jsonb_object_agg(
                                    coalesce((c).name, (oc).name),
                                    case
                                        when (c).name is null then (oc).value
                                        else (c).value
                                    end
                                )
                            from
                                unnest(columns) c
                                full outer join unnest(old_columns) oc
                                    on (c).name = (oc).name
                            where
                                coalesce((c).is_selectable, (oc).is_selectable)
                                and ( not error_record_exceeds_max_size or (octet_length((c).value::text) <= 64))
                        )
                    )
                else '{}'::jsonb
            end
            || case
                when action = 'UPDATE' then
                    jsonb_build_object(
                            'old_record',
                            (
                                select jsonb_object_agg((c).name, (c).value)
                                from unnest(old_columns) c
                                where
                                    (c).is_selectable
                                    and ( not error_record_exceeds_max_size or (octet_length((c).value::text) <= 64))
                            )
                        )
                when action = 'DELETE' then
                    jsonb_build_object(
                        'old_record',
                        (
                            select jsonb_object_agg((c).name, (c).value)
                            from unnest(old_columns) c
                            where
                                (c).is_selectable
                                and ( not error_record_exceeds_max_size or (octet_length((c).value::text) <= 64))
                                and ( not is_rls_enabled or (c).is_pkey )
                        )
                    )
                else '{}'::jsonb
            end;

            if is_rls_enabled and action <> 'DELETE' then
                if (select 1 from pg_prepared_statements where name = 'walrus_rls_stmt' limit 1) > 0 then
                    deallocate walrus_rls_stmt;
                end if;
                execute realtime.build_prepared_statement_sql('walrus_rls_stmt', entity_, columns);
            end if;

            visible_to_subscription_ids = '{}';

            for subscription_id, claims in (
                    select
                        subs.subscription_id,
                        subs.claims
                    from
                        unnest(subscriptions) subs
                    where
                        subs.entity = entity_
                        and subs.claims_role = working_role
                        and (
                            realtime.is_visible_through_filters(columns, subs.filters)
                            or (
                              action = 'DELETE'
                              and realtime.is_visible_through_filters(old_columns, subs.filters)
                            )
                        )
            ) loop

                if not is_rls_enabled or action = 'DELETE' then
                    visible_to_subscription_ids = visible_to_subscription_ids || subscription_id;
                else
                    perform
                        set_config('role', trim(both '"' from working_role::text), true),
                        set_config('request.jwt.claims', claims::text, true);

                    execute 'execute walrus_rls_stmt' into subscription_has_access;

                    if subscription_has_access then
                        visible_to_subscription_ids = visible_to_subscription_ids || subscription_id;
                    end if;
                end if;
            end loop;

            perform set_config('role', null, true);

            return next (
                output,
                is_rls_enabled,
                visible_to_subscription_ids,
                case
                    when error_record_exceeds_max_size then array['Error 413: Payload Too Large']
                    else '{}'
                end
            )::realtime.wal_rls;

        end if;
    end loop;

    perform set_config('role', null, true);
    end;
    $func$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION realtime.list_changes(
        publication name,
        slot_name name,
        max_changes integer,
        max_record_bytes integer
    )
    RETURNS SETOF realtime.wal_rls
    LANGUAGE sql
    SET log_min_messages TO 'fatal'
    AS $func$
      with pub as (
        select
          concat_ws(
            ',',
            case when bool_or(pubinsert) then 'insert' else null end,
            case when bool_or(pubupdate) then 'update' else null end,
            case when bool_or(pubdelete) then 'delete' else null end
          ) as w2j_actions,
          coalesce(
            string_agg(
              realtime.quote_wal2json(format('%I.%I', schemaname, tablename)::regclass),
              ','
            ) filter (where ppt.tablename is not null and ppt.tablename not like '% %'),
            ''
          ) w2j_add_tables
        from
          pg_publication pp
          left join pg_publication_tables ppt
            on pp.pubname = ppt.pubname
        where
          pp.pubname = publication
        group by
          pp.pubname
        limit 1
      ),
      w2j as (
        select
          x.*, pub.w2j_add_tables
        from
          pub,
          pg_logical_slot_get_changes(
            slot_name, null, max_changes,
            'include-pk', 'true',
            'include-transaction', 'false',
            'include-timestamp', 'true',
            'include-type-oids', 'true',
            'format-version', '2',
            'actions', pub.w2j_actions,
            'add-tables', pub.w2j_add_tables
          ) x
      )
      select
        xyz.wal,
        xyz.is_rls_enabled,
        xyz.subscription_ids,
        xyz.errors
      from
        w2j,
        realtime.apply_rls(
          wal := w2j.data::jsonb,
          max_record_bytes := max_record_bytes
        ) xyz(wal, is_rls_enabled, subscription_ids, errors)
      where
        w2j.w2j_add_tables <> ''
        and xyz.subscription_ids[1] is not null
    $func$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION realtime.send(payload jsonb, event text, topic text, private boolean DEFAULT true)
    RETURNS void
    LANGUAGE plpgsql
    AS $func$
    DECLARE
      generated_id uuid;
      final_payload jsonb;
    BEGIN
      BEGIN
        generated_id := gen_random_uuid();

        IF payload ? 'id' THEN
          final_payload := payload;
        ELSE
          final_payload := jsonb_set(payload, '{id}', to_jsonb(generated_id));
        END IF;

        EXECUTE format('SET LOCAL realtime.topic TO %L', topic);

        INSERT INTO realtime.messages (id, payload, event, topic, private, extension)
        VALUES (generated_id, final_payload, event, topic, private, 'broadcast');
      EXCEPTION
        WHEN OTHERS THEN
          RAISE WARNING 'ErrorSendingBroadcastMessage: %', SQLERRM;
      END;
    END;
    $func$;
    """)

    execute("""
    CREATE OR REPLACE FUNCTION realtime.broadcast_changes(
        topic_name text,
        event_name text,
        operation text,
        table_name text,
        table_schema text,
        new record,
        old record,
        level text DEFAULT 'ROW'::text
    )
    RETURNS void
    LANGUAGE plpgsql
    AS $func$
    DECLARE
        row_data jsonb := '{}'::jsonb;
    BEGIN
        IF level = 'STATEMENT' THEN
            RAISE EXCEPTION 'function can only be triggered for each row, not for each statement';
        END IF;
        IF operation = 'INSERT' OR operation = 'UPDATE' OR operation = 'DELETE' THEN
            row_data := jsonb_build_object('old_record', OLD, 'record', NEW, 'operation', operation, 'table', table_name, 'schema', table_schema);
            PERFORM realtime.send (row_data, event_name, topic_name);
        ELSE
            RAISE EXCEPTION 'Unexpected operation type: %', operation;
        END IF;
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'Failed to process the row: %', SQLERRM;
    END;
    $func$;
    """)
  end

  defp create_indexes do
    execute("""
    CREATE INDEX IF NOT EXISTS ix_realtime_subscription_entity
        ON realtime.subscription USING btree (entity)
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS subscription_subscription_id_entity_filters_action_filter_key
        ON realtime.subscription USING btree (subscription_id, entity, filters, action_filter)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS messages_inserted_at_topic_index
        ON ONLY realtime.messages USING btree (inserted_at DESC, topic)
        WHERE ((extension = 'broadcast'::text) AND (private IS TRUE))
    """)
  end

  defp create_trigger do
    execute("DROP TRIGGER IF EXISTS tr_check_filters ON realtime.subscription")

    execute("""
    CREATE TRIGGER tr_check_filters
        BEFORE INSERT OR UPDATE ON realtime.subscription
        FOR EACH ROW EXECUTE FUNCTION realtime.subscription_check_filters()
    """)
  end

  defp configure_grants do
    execute("GRANT USAGE ON SCHEMA realtime TO postgres, anon, authenticated, service_role, supabase_realtime_admin")
    execute("GRANT CREATE ON SCHEMA realtime TO supabase_realtime_admin")
    execute("GRANT ALL ON ALL TABLES IN SCHEMA realtime TO supabase_realtime_admin")
    execute("GRANT ALL ON ALL SEQUENCES IN SCHEMA realtime TO supabase_realtime_admin")
    execute("GRANT ALL ON ALL FUNCTIONS IN SCHEMA realtime TO supabase_realtime_admin")
    execute("GRANT SELECT ON realtime.subscription TO anon, authenticated, service_role")
    execute("GRANT SELECT ON realtime.schema_migrations TO anon, authenticated, service_role")
    execute("GRANT SELECT, INSERT, UPDATE ON realtime.messages TO postgres, anon, authenticated, service_role")
    execute("GRANT DELETE, TRUNCATE, REFERENCES, TRIGGER ON realtime.messages TO postgres")
    execute("GRANT USAGE ON ALL SEQUENCES IN SCHEMA realtime TO anon, authenticated, service_role")
  end

  defp configure_ownership do
    execute("ALTER TABLE realtime.messages OWNER TO supabase_realtime_admin")
    execute("ALTER FUNCTION realtime.topic() OWNER TO supabase_realtime_admin")
  end

  defp configure_rls do
    execute("ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY")
  end
end
