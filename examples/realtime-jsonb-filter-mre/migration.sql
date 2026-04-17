-- ============================================
-- Supabase Realtime: JSONB Filter Workaround (FIXED)
-- ============================================

-- Extensions & Schema
create extension if not exists pgcrypto;
create schema if not exists pgboss;

-- Table
create table if not exists pgboss.job (
  id uuid primary key default gen_random_uuid(),
  data jsonb,
  created_at timestamp default now()
);

-- 1) Add scalar column for filtering
alter table pgboss.job
  add column if not exists organization_id text;

-- 2) Backfill existing rows
update pgboss.job
set organization_id = data->>'organization_id'
where organization_id is distinct from data->>'organization_id';

-- 3) Trigger function (schema-safe)
create or replace function pgboss.sync_organization_id()
returns trigger as $$
begin
  new.organization_id := new.data->>'organization_id';
  return new;
end;
$$ language plpgsql;

-- 4) Trigger
drop trigger if exists sync_organization_id_trigger on pgboss.job;

create trigger sync_organization_id_trigger
before insert or update on pgboss.job
for each row
execute function pgboss.sync_organization_id();

-- 5) Index
create index if not exists idx_job_organization_id
on pgboss.job (organization_id);

-- 6) Enable RLS
alter table pgboss.job enable row level security;
alter table pgboss.job replica identity full;

-- 7) RLS Policy (IMPORTANT)
-- Replace with your JWT structure if needed
drop policy if exists "org based access" on pgboss.job;

create policy "org based access"
on pgboss.job
for select
using (
  organization_id = auth.jwt() ->> 'organization_id'
);

-- (Optional: allow inserts if needed)
drop policy if exists "allow insert" on pgboss.job;

create policy "allow insert"
on pgboss.job
for insert
with check (true);

-- 8) Add to Realtime publication (idempotent)
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'pgboss'
      and tablename = 'job'
  ) then
    alter publication supabase_realtime add table pgboss.job;
  end if;
end $$;