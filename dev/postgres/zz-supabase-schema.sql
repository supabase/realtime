do $$
begin
  if not exists (select from pg_roles where rolname = 'postgres') then
    create role postgres with login superuser createdb createrole replication bypassrls password 'postgres';
  end if;
  if not exists (select from pg_roles where rolname = 'supabase_admin') then
    create role supabase_admin with login superuser createdb createrole replication bypassrls password 'postgres';
  end if;
  if not exists (select from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end$$;

create schema if not exists _realtime;
create schema if not exists realtime;

-- auth schema and functions below are only used by tests
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'auth') then
    create schema auth;

    execute $f$
      create function auth.uid() returns uuid language sql stable as $body$
        select coalesce(
          nullif(current_setting('request.jwt.claim.sub', true), ''),
          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
        )::uuid
      $body$
    $f$;

    execute $f$
      create function auth.role() returns text language sql stable as $body$
        select coalesce(
          nullif(current_setting('request.jwt.claim.role', true), ''),
          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
        )::text
      $body$
    $f$;

    execute $f$
      create function auth.email() returns text language sql stable as $body$
        select coalesce(
          nullif(current_setting('request.jwt.claim.email', true), ''),
          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'email')
        )::text
      $body$
    $f$;

    execute $f$
      create function auth.jwt() returns jsonb language sql stable as $body$
        select coalesce(
          nullif(current_setting('request.jwt.claim', true), ''),
          nullif(current_setting('request.jwt.claims', true), '')
        )::jsonb
      $body$
    $f$;

    grant usage on schema auth to anon, authenticated, service_role, supabase_admin;
    grant execute on all functions in schema auth to anon, authenticated, service_role, supabase_admin;
    alter default privileges in schema auth grant execute on functions to anon, authenticated, service_role, supabase_admin;
  end if;
end$$;
