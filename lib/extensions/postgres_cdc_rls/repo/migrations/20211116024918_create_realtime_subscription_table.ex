defmodule Realtime.Extensions.Rls.Repo.Migrations.CreateRealtimeSubscriptionTable do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("create type realtime.equality_op as enum(
      'eq', 'neq', 'lt', 'lte', 'gt', 'gte'
    );")

    execute("create type realtime.user_defined_filter as (
      column_name text,
      op realtime.equality_op,
      value text
    );")

    execute("create table realtime.subscription (
      -- Tracks which users are subscribed to each table
      id bigint not null generated always as identity,
      user_id uuid not null,
      -- Populated automatically by trigger. Required to enable auth.email()
      email varchar(255),
      entity regclass not null,
      filters realtime.user_defined_filter[] not null default '{}',
      created_at timestamp not null default timezone('utc', now()),

      constraint pk_subscription primary key (id),
      unique (entity, user_id, filters)
    )")

    execute(
      "create index ix_realtime_subscription_entity on realtime.subscription using hash (entity)"
    )
  end
end
