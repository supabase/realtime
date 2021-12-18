/*
    SETUP
*/
-- Set up Realtime
create schema if not exists realtime;
create publication supabase_realtime for all tables;

-- Extension namespacing
create schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;

-- Set up auth roles for the developer
create role anon          nologin noinherit;
create role authenticated nologin noinherit; -- "logged in" user: web_user, app_user, etc
create role service_role  nologin noinherit bypassrls; -- allow developers to create JWT's that bypass their policies

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public grant all on tables    to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;

create schema if not exists auth;

create or replace function auth.uid()
returns uuid
language sql stable
as $$
  select
  nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')
    ),
    ''
  )::uuid
$$;

create or replace function auth.role() 
returns text 
language sql stable
as $$
  select 
  	coalesce(
		current_setting('request.jwt.claim.role', true),
		(current_setting('request.jwt.claims', true)::jsonb ->> 'role')
	)::text
$$;

create or replace function auth.email() 
returns text 
language sql stable
as $$
  select 
  	coalesce(
		current_setting('request.jwt.claim.email', true),
		(current_setting('request.jwt.claims', true)::jsonb ->> 'email')
	)::text
$$;
