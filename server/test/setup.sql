-- ALTER SYSTEM SET wal_level='logical';
-- ALTER SYSTEM SET max_replication_slots='5';

-- Copied from https://github.com/supabase/walrus/blob/f54b2b1657c8348ce9e22c92092eaa50bfa8993a/sql/setup.sql

/*
    SETUP
*/
-- Set up reatime
do $$
declare
  is_pub boolean := (select exists(select * from pg_publication where pubname='supabase_realtime'));
begin
  if not is_pub then
	create publication supabase_realtime for all tables;
  end if;
end $$;

-- Extension namespacing
create schema if not exists extensions;
create extension if not exists "uuid-ossp"      with schema extensions;



DO $$
BEGIN
-- Developer roles
  create role anon                nologin noinherit;
  create role authenticated       nologin noinherit; -- "logged in" user: web_user, app_user, etc
  create role service_role        nologin noinherit bypassrls; -- allow developers to create JWT's that bypass their policies
  create user authenticator noinherit;
EXCEPTION WHEN duplicate_object THEN RAISE NOTICE '%, skipping', SQLERRM USING ERRCODE = SQLSTATE;
END
$$;
grant anon              to authenticator;
grant authenticated     to authenticator;
grant service_role      to authenticator;

grant usage                     on schema public to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on tables to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to postgres, anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to postgres, anon, authenticated, service_role;

CREATE SCHEMA IF NOT EXISTS auth AUTHORIZATION postgres;

-- auth.users definition
CREATE TABLE IF NOT EXISTS auth.users (
    instance_id uuid NULL,
    id uuid NOT NULL,
    aud varchar(255) NULL,
    "role" varchar(255) NULL,
    email varchar(255) NULL,
    encrypted_password varchar(255) NULL,
    confirmed_at timestamptz NULL,
    invited_at timestamptz NULL,
    confirmation_token varchar(255) NULL,
    confirmation_sent_at timestamptz NULL,
    recovery_token varchar(255) NULL,
    recovery_sent_at timestamptz NULL,
    email_change_token varchar(255) NULL,
    email_change varchar(255) NULL,
    email_change_sent_at timestamptz NULL,
    last_sign_in_at timestamptz NULL,
    raw_app_meta_data jsonb NULL,
    raw_user_meta_data jsonb NULL,
    is_super_admin bool NULL,
    created_at timestamptz NULL,
    updated_at timestamptz NULL,
    CONSTRAINT users_pkey PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS users_instance_id_email_idx ON auth.users USING btree (instance_id, email);
CREATE INDEX IF NOT EXISTS users_instance_id_idx ON auth.users USING btree (instance_id);
-- auth.refresh_tokens definition
CREATE TABLE IF NOT EXISTS auth.refresh_tokens (
    instance_id uuid NULL,
    id bigserial NOT NULL,
    "token" varchar(255) NULL,
    user_id varchar(255) NULL,
    revoked bool NULL,
    created_at timestamptz NULL,
    updated_at timestamptz NULL,
    CONSTRAINT refresh_tokens_pkey PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS refresh_tokens_instance_id_idx ON auth.refresh_tokens USING btree (instance_id);
CREATE INDEX IF NOT EXISTS refresh_tokens_instance_id_user_id_idx ON auth.refresh_tokens USING btree (instance_id, user_id);
CREATE INDEX IF NOT EXISTS  refresh_tokens_token_idx ON auth.refresh_tokens USING btree (token);
-- auth.instances definition
CREATE TABLE IF NOT EXISTS auth.instances (
    id uuid NOT NULL,
    uuid uuid NULL,
    raw_base_config text NULL,
    created_at timestamptz NULL,
    updated_at timestamptz NULL,
    CONSTRAINT instances_pkey PRIMARY KEY (id)
);
-- auth.audit_log_entries definition
CREATE TABLE IF NOT EXISTS auth.audit_log_entries (
    instance_id uuid NULL,
    id uuid NOT NULL,
    payload json NULL,
    created_at timestamptz NULL,
    CONSTRAINT audit_log_entries_pkey PRIMARY KEY (id)
);
CREATE INDEX IF NOT EXISTS audit_logs_instance_id_idx ON auth.audit_log_entries USING btree (instance_id);
-- auth.schema_migrations definition
-- DROP TABLE IF EXISTS auth.schema_migrations;
CREATE TABLE IF NOT EXISTS auth.schema_migrations (
    "version" varchar(255) NOT NULL,
    CONSTRAINT schema_migrations_pkey PRIMARY KEY ("version")
);
-- INSERT INTO auth.schema_migrations (version)
-- VALUES  ('20171026211738'),
--         ('20171026211808'),
--         ('20171026211834'),
--         ('20180103212743'),
--         ('20180108183307'),
--         ('20180119214651'),
--         ('20180125194653');
-- Gets the User ID from the request cookie
create or replace function auth.uid() returns uuid as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$ language sql stable;
-- Gets the User Role from the request cookie
create or replace function auth.role() returns text as $$
  select nullif(current_setting('request.jwt.claim.role', true), '')::text;
$$ language sql stable;
-- Gets the User Email from the request cookie
create or replace function auth.email() returns text as $$
  select nullif(current_setting('request.jwt.claim.email', true), '')::text;
$$ language sql stable;
GRANT ALL PRIVILEGES ON SCHEMA auth TO postgres;
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA auth TO postgres;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA auth TO postgres;
ALTER ROLE postgres SET search_path = "$user", public, auth;

GRANT USAGE ON SCHEMA auth TO anon, authenticated, service_role;

-- Copied from https://github.com/supabase/realtime/blob/32f2f90b6fdd29c184544f41ce71bbe81234006a/sql/walrus--0.1.sql

/*
    WALRUS:
        Write Ahead Log Realtime Unified Security
*/

create schema if not exists cdc;
grant usage on schema cdc to postgres;
grant usage on schema cdc to authenticated;

do $$ begin
  create type cdc.equality_op as enum(
      'eq', 'neq', 'lt', 'lte', 'gt', 'gte'
  );
  create type cdc.action as enum ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'ERROR');
  create type cdc.user_defined_filter as (
      column_name text,
      op cdc.equality_op,
      value text
  );
  create type cdc.wal_column as (
      name text,
      type text,
      value jsonb,
      is_pkey boolean,
      is_selectable boolean
  );
  create type cdc.wal_rls as (
      wal jsonb,
      is_rls_enabled boolean,
      users uuid[],
      errors text[]
  );
exception
    when duplicate_object then null;
end $$;


create table if not exists cdc.subscription (
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
create index if not exists ix_cdc_subscription_entity on cdc.subscription using hash (entity);


create or replace function cdc.subscription_check_filters()
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

drop trigger if exists tr_check_filters on cdc.subscription;
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

create or replace function cdc.cast(val text, type_ regtype)
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
create or replace function cdc.apply_rls(wal jsonb)
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
begin

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
        when action in ('INSERT', 'UPDATE') then
            jsonb_build_object(
                'record',
                (select jsonb_object_agg((c).name, (c).value) from unnest(columns) c where (c).is_selectable)
            )
        else '{}'::jsonb
    end
    -- Add "old_record" key for update and delete
    || case
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
        array[]::text[]
    )::cdc.wal_rls;
end;
$$;

CREATE TABLE IF NOT EXISTS public.todos (
  id bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  details text,
  user_id bigint NOT NULL
);
