-- Copied from https://github.com/supabase/walrus/blob/626b6d7d5fcb2d6bd825941e69bc3473c7e8cbea/sql/walrus--0.1.sql

/*
    WALRUS:
        Write Ahead Log Realtime Unified Security
*/

create schema cdc;
grant usage on schema cdc to postgres;
grant usage on schema cdc to authenticated;


create type cdc.equality_op as enum(
    'eq', 'neq', 'lt', 'lte', 'gt', 'gte'
);


create type cdc.action as enum ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'ERROR');


create type cdc.user_defined_filter as (
    column_name text,
    op cdc.equality_op,
    value text
);


create table cdc.subscription (
    -- Tracks which users are subscribed to each table
    id bigint not null generated always as identity,
    user_id uuid not null references auth.users(id) on delete cascade,
    -- Populated automatically by trigger. Required to enable auth.email()
    email varchar(255),
    entity regclass not null,
    filters cdc.user_defined_filter[] not null default '{}',
    created_at timestamp not null default timezone('utc', now()),

    constraint pk_subscription primary key (id),
    unique (entity, user_id, filters)
);
create index ix_cdc_subscription_entity on cdc.subscription using hash (entity);


create function cdc.subscription_check_filters()
    returns trigger
    language plpgsql
as $$
/*
Validates that the user defined filters for a subscription:
- refer to valid columns that "authenticated" may access
- values are coercable to the correct column type
*/
declare
    col_names text[] = coalesce(
            array_agg(c.column_name order by c.ordinal_position),
            '{}'::text[]
        )
        from
            information_schema.columns c
        where
            (quote_ident(c.table_schema) || '.' || quote_ident(c.table_name))::regclass = new.entity
            and pg_catalog.has_column_privilege('authenticated', new.entity, c.column_name, 'SELECT');
    filter cdc.user_defined_filter;
    col_type text;
begin
    for filter in select * from unnest(new.filters) loop
        -- Filtered column is valid
        if not filter.column_name = any(col_names) then
            raise exception 'invalid column for filter %', filter.column_name;
        end if;

        -- Type is sanitized and safe for string interpolation
        col_type = (
            select atttypid::regtype
            from pg_catalog.pg_attribute
            where attrelid = new.entity
                  and attname = filter.column_name
        )::text;
        if col_type is null then
            raise exception 'failed to lookup type for column %', filter.column_name;
        end if;
        -- raises an exception if value is not coercable to type
        perform format('select %s::%I', filter.value, col_type);
    end loop;

    -- Apply consistent order to filters so the unique constraint on
    -- (user_id, entity, filters) can't be tricked by a different filter order
    new.filters = coalesce(
        array_agg(f order by f.column_name, f.op, f.value),
        '{}'
    ) from unnest(new.filters) f;

    -- Avoids the 'authenticated' role requiring access to auth.users
    new.email = (select u.email from auth.users u where u.id = new.user_id);

    return new;
end;
$$;

create trigger tr_check_filters
    before insert or update on cdc.subscription
    for each row
    execute function cdc.subscription_check_filters();


grant all on cdc.subscription to postgres;
grant select on cdc.subscription to authenticated;


create or replace function cdc.quote_wal2json(entity regclass)
    returns text
    language sql
    immutable
    strict
as $$
    select
        (
            select string_agg('\' || ch,'')
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
            select string_agg('\' || ch,'')
            from unnest(string_to_array(pc.relname::text, null)) with ordinality x(ch, idx)
            where
                not (x.idx = 1 and x.ch = '"')
                and not (
                    x.idx = array_length(string_to_array(nsp.nspname::text, null), 1)
                    and x.ch = '"'
                )
        )
    from
        pg_class pc
        join pg_namespace nsp
            on pc.relnamespace = nsp.oid
    where
        pc.oid = entity
$$;


create or replace function cdc.check_equality_op(
    op cdc.equality_op,
    type_ regtype,
    val_1 text,
    val_2 text
)
    returns bool
    immutable
    language plpgsql
as $$
/*
Casts *val_1* and *val_2* as type *type_* and check the *op* condition for truthiness
*/
declare
    op_symbol text = (
        case
            when op = 'eq' then '='
            when op = 'neq' then '!='
            when op = 'lt' then '<'
            when op = 'lte' then '<='
            when op = 'gt' then '>'
            when op = 'gte' then '>='
            else 'UNKNOWN OP'
        end
    );
    res boolean;
begin
    execute format('select %L::'|| type_::text || ' ' || op_symbol || ' %L::'|| type_::text, val_1, val_2) into res;
    return res;
end;
$$;


create type cdc.wal_column as (
    name text,
    type text,
    value jsonb,
    is_pkey boolean,
    is_selectable boolean
);

create or replace function cdc.build_prepared_statement_sql(
    prepared_statement_name text,
    entity regclass,
    columns cdc.wal_column[]
)
    returns text
    language sql
as $$
/*
Builds a sql string that, if executed, creates a prepared statement to
tests retrive a row from *entity* by its primary key columns.

Example
    select cdc.build_prepared_statment_sql('public.notes', '{"id"}'::text[], '{"bigint"}'::text[])
*/
    select
'prepare ' || prepared_statement_name || ' as
    select
        exists(
            select
                1
            from
                ' || entity || '
            where
                ' || string_agg(quote_ident(pkc.name) || '=' || quote_nullable(pkc.value) , ' and ') || '
        )'
    from
        unnest(columns) pkc
    where
        pkc.is_pkey
    group by
        entity
$$;


create type cdc.wal_rls as (
    wal jsonb,
    is_rls_enabled boolean,
    users uuid[],
    errors text[]
);

create function cdc.cast(val text, type_ regtype)
    returns jsonb
    immutable
    language plpgsql
as $$
declare
    res jsonb;
begin
    execute format('select to_jsonb(%L::'|| type_::text || ')', val)  into res;
    return res;
end
$$;



create or replace function cdc.is_visible_through_filters(columns cdc.wal_column[], filters cdc.user_defined_filter[])
    returns bool
    language sql
    immutable
as $$
/*
Should the record be visible (true) or filtered out (false) after *filters* are applied
*/
    select
        -- Default to allowed when no filters present
        coalesce(
            sum(
                cdc.check_equality_op(
                    op:=f.op,
                    type_:=col.type::regtype,
                    -- cast jsonb to text
                    val_1:=col.value #>> '{}',
                    val_2:=f.value
                )::int
            ) = count(1),
            true
        )
    from
        unnest(filters) f
        join unnest(columns) col
            on f.column_name = col.name;
$$;


create or replace function cdc.apply_rls(wal jsonb, max_record_bytes int = 1024 * 1024)
    returns cdc.wal_rls
    language plpgsql
    volatile
as $$
declare
    -- Regclass of the table e.g. public.notes
    entity_ regclass = (quote_ident(wal ->> 'schema') || '.' || quote_ident(wal ->> 'table'))::regclass;

    -- I, U, D, T: insert, update ...
    action cdc.action = (
        case wal ->> 'action'
            when 'I' then 'INSERT'
            when 'U' then 'UPDATE'
            when 'D' then 'DELETE'
            when 'T' then 'TRUNCATE'
            else 'ERROR'
        end
    );

    -- Is row level security enabled for the table
    is_rls_enabled bool = relrowsecurity from pg_class where oid = entity_;

    -- Subscription vars
    user_id uuid;
    email varchar(255);
    user_has_access bool;
    is_visible_to_user boolean;
    visible_to_user_ids uuid[] = '{}';

    -- user subscriptions to the wal record's table
    subscriptions cdc.subscription[] =
            array_agg(sub)
        from
            cdc.subscription sub
        where
            sub.entity = entity_;

    -- structured info for wal's columns
    columns cdc.wal_column[] =
        array_agg(
            (
                x->>'name',
                x->>'type',
                cdc.cast((x->'value') #>> '{}', (x->>'type')::regtype),
                (pks ->> 'name') is not null,
                pg_catalog.has_column_privilege('authenticated', entity_, x->>'name', 'SELECT')
            )::cdc.wal_column
        )
        from
            jsonb_array_elements(wal -> 'columns') x
            left join jsonb_array_elements(wal -> 'pk') pks
                on (x ->> 'name') = (pks ->> 'name');

    -- previous identity values for update/delete
    old_columns cdc.wal_column[] =
        array_agg(
            (
                x->>'name',
                x->>'type',
                cdc.cast((x->'value') #>> '{}', (x->>'type')::regtype),
                (pks ->> 'name') is not null,
                pg_catalog.has_column_privilege('authenticated', entity_, x->>'name', 'SELECT')
            )::cdc.wal_column
        )
        from
            jsonb_array_elements(wal -> 'identity') x
            left join jsonb_array_elements(wal -> 'pk') pks
                on (x ->> 'name') = (pks ->> 'name');

    output jsonb;

    -- Error states
    error_record_exceeds_max_size boolean = octet_length(wal::text) > max_record_bytes;
    error_unauthorized boolean = not pg_catalog.has_any_column_privilege('authenticated', entity_, 'SELECT');

    errors text[] = case
        when error_record_exceeds_max_size then array['Error 413: Payload Too Large']
        else '{}'::text[]
    end;
begin

    -- The 'authenticated' user does not have SELECT permission on any of the columns for the entity_
    if error_unauthorized is true then
        return (
            null,
            null,
            visible_to_user_ids,
            array['Error 401: Unauthorized']
        )::cdc.wal_rls;
    end if;

    -------------------------------
    -- Build Output JSONB Object --
    -------------------------------
    output = jsonb_build_object(
        'schema', wal ->> 'schema',
        'table', wal ->> 'table',
        'type', action,
        'commit_timestamp', (wal ->> 'timestamp')::text::timestamp with time zone,
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
                and pg_catalog.has_column_privilege('authenticated', entity_, pa.attname, 'SELECT')
        )
    )
    -- Add "record" key for insert and update
    || case
        when error_record_exceeds_max_size then jsonb_build_object('record', '{}'::jsonb)
        when action in ('INSERT', 'UPDATE') then
            jsonb_build_object(
                'record',
                (select jsonb_object_agg((c).name, (c).value) from unnest(columns) c where (c).is_selectable)
            )
        else '{}'::jsonb
    end
    -- Add "old_record" key for update and delete
    || case
        when error_record_exceeds_max_size then jsonb_build_object('old_record', '{}'::jsonb)
        when action in ('UPDATE', 'DELETE') then
            jsonb_build_object(
                'old_record',
                (select jsonb_object_agg((c).name, (c).value) from unnest(old_columns) c where (c).is_selectable)
            )
        else '{}'::jsonb
    end;

    if action in ('TRUNCATE', 'DELETE') then
        visible_to_user_ids = array_agg(s.user_id) from unnest(subscriptions) s;
    else
        -- If RLS is on and someone is subscribed to the table prep
        if is_rls_enabled and array_length(subscriptions, 1) > 0 then
            perform
                set_config('role', 'authenticated', true),
                set_config('request.jwt.claim.role', 'authenticated', true);

            if (select 1 from pg_prepared_statements where name = 'walrus_rls_stmt' limit 1) > 0 then
                deallocate walrus_rls_stmt;
            end if;
            execute cdc.build_prepared_statement_sql('walrus_rls_stmt', entity_, columns);

        end if;

        -- For each subscribed user
        for user_id, email, is_visible_to_user in (
                select
                    subs.user_id,
                    subs.email,
                    cdc.is_visible_through_filters(columns, subs.filters)
                from
                    unnest(subscriptions) subs
        )
        loop
            if is_visible_to_user then
                -- If RLS is off, add to visible users
                if not is_rls_enabled then
                    visible_to_user_ids = visible_to_user_ids || user_id;
                else
                    -- Check if RLS allows the user to see the record
                    perform
                        set_config('request.jwt.claim.sub', user_id::text, true),
                        set_config('request.jwt.claim.email', email::text, true);
                    execute 'execute walrus_rls_stmt' into user_has_access;

                    if user_has_access then
                        visible_to_user_ids = visible_to_user_ids || user_id;
                    end if;

                end if;
            end if;
        end loop;

        perform (
            set_config('role', null, true)
        );

    end if;

    return (
        output,
        is_rls_enabled,
        visible_to_user_ids,
        errors
    )::cdc.wal_rls;
end;
$$;
