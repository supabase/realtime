defmodule Realtime.RLS.Repo.Migrations.CreateCdcSubscriptionTable do
  use Ecto.Migration

  def change do
    execute "create type cdc.equality_op as enum(
      'eq', 'neq', 'lt', 'lte', 'gt', 'gte'
    );"
    execute "create type cdc.user_defined_filter as (
      column_name text,
      op cdc.equality_op,
      value text
    );"
    execute "create table if not exists cdc.subscription (
      -- Tracks which users are subscribed to each table
      id bigint not null generated always as identity,
      user_id uuid not null,
      -- Populated automatically by trigger. Required to enable auth.email()
      email varchar(255),
      entity regclass not null,
      filters cdc.user_defined_filter[] not null default '{}',
      created_at timestamp not null default timezone('utc', now()),

      constraint pk_subscription primary key (id),
      unique (entity, user_id, filters)
    )"
    execute "create index if not exists ix_cdc_subscription_entity on cdc.subscription using hash (entity)"
    execute "grant all on cdc.subscription to postgres"
    execute "grant select on cdc.subscription to authenticated"
  end
end
