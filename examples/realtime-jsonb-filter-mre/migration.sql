-- Supabase Realtime: JSONB Filter Workaround
-- ============================================
-- 
-- Issue: Realtime postgres_changes filters only support direct column filters
-- (e.g., col=eq.value), not JSONB expressions (e.g., data->>organization_id=eq.value).
--
-- Solution: Keep JSONB column for flexible payloads, add a dedicated scalar column
-- for filtering, and sync with a database trigger.
--
-- This migration adds the necessary schema, backfill, trigger, and index.

create extension if not exists pgcrypto;
create schema if not exists pgboss;

create table if not exists pgboss.job (
  id uuid primary key default gen_random_uuid(),
  data jsonb,
  created_at timestamp default now()
);

-- 1) Add dedicated scalar column for Realtime filters
alter table pgboss.job
  add column if not exists organization_id text;

-- 2) Backfill existing rows from JSONB payload
update pgboss.job
set organization_id = data->>'organization_id'
where organization_id is distinct from data->>'organization_id';

-- 3) Keep scalar column in sync with JSONB on INSERT/UPDATE
create or replace function sync_organization_id()
returns trigger as $$
begin
  new.organization_id := new.data->>'organization_id';
  return new;
end;
$$ language plpgsql;

drop trigger if exists sync_organization_id_trigger on pgboss.job;
create trigger sync_organization_id_trigger
before insert or update on pgboss.job
for each row
execute function sync_organization_id();

-- 4) Index for efficient organization-scoped queries and Realtime filtering
create index if not exists idx_job_organization_id on pgboss.job (organization_id);

-- 5) Realtime + RLS setup (for testing/demo)
alter table pgboss.job enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'pgboss'
      and tablename = 'job'
      and policyname = 'allow_all_for_testing'
  ) then
    create policy allow_all_for_testing
      on pgboss.job
      for all
      to anon, authenticated
      using (true)
      with check (true);
  end if;
end $$;

alter publication supabase_realtime add table pgboss.job;
