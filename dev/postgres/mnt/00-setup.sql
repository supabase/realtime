-- Copied from https://github.com/supabase/walrus/blob/5dd35b38cf80e3c99b0c91b7e0118b7993e45cf5/sql/setup.sql

/*
    SETUP
*/
-- Set up Realtime
create schema if not exists realtime;
create publication supabase_realtime for all tables;

-- Extension namespacing
create schema extensions;
create extension if not exists "uuid-ossp"      with schema extensions;

-- Developer role
create role authenticated       nologin noinherit; -- "logged in" user: web_user, app_user, etc

grant usage                     on schema public to authenticated;
alter default privileges in schema public grant all on tables to authenticated;
alter default privileges in schema public grant all on functions to authenticated;
alter default privileges in schema public grant all on sequences to authenticated;

CREATE SCHEMA IF NOT EXISTS auth;

-- Gets the User ID from the request cookie
create or replace function auth.uid() returns uuid as $$
    select
        coalesce(
            current_setting('request.jwt.claim.sub', true),
            current_setting('request.jwt.claims', true)::jsonb ->> 'sub'
        )::uuid;
$$ language sql stable;
-- Gets the User Role from the request cookie
create or replace function auth.role() returns text as $$
  select
        coalesce(
            current_setting('request.jwt.claim.role', true),
            current_setting('request.jwt.claims', true)::jsonb ->> 'role'
        )::text;
$$ language sql stable;

-- Gets the User Email from the request cookie
create or replace function auth.email() returns text as $$
  select
        coalesce(
            current_setting('request.jwt.claim.email', true),
            current_setting('request.jwt.claims', true)::jsonb ->> 'email'
        )::text;
$$ language sql stable;

ALTER ROLE postgres SET search_path = "$user", public, auth;

GRANT USAGE ON SCHEMA auth TO authenticated;
