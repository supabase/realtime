create table "realtime"."subscription" (
  "id"              bigint   generated always as identity not null,
  "subscription_id" uuid     not null,
  "entity"          regclass not null,
  constraint "pk_subscription" primary key (id)
);

alter table "realtime"."subscription"
  owner to "supabase_realtime_admin";

alter table "realtime"."subscription"
  add column "filters" realtime.user_defined_filter[] not null default '{}'::realtime.user_defined_filter[];

alter table "realtime"."subscription"
  add column "claims" jsonb not null;

create index ix_realtime_subscription_entity on realtime.subscription using btree (entity);

create trigger tr_check_filters
  before insert or update on realtime.subscription
  for each row
  execute function realtime.subscription_check_filters();

grant usage on sequence "realtime"."subscription_id_seq" to "anon", "authenticated", "service_role";

grant select on table "realtime"."subscription" to "anon", "authenticated", "service_role";

alter table "realtime"."subscription"
  add column "claims_role" regrole generated always as (realtime.to_regrole((claims ->> 'role'::text))) stored not null;

alter table "realtime"."subscription"
  add column "created_at" timestamp without time zone not null default timezone('utc'::text, now());

alter table "realtime"."subscription"
  add column "action_filter" text default '*'::text;

alter table "realtime"."subscription"
  add column "selected_columns" text[];

alter table "realtime"."subscription"
  add constraint "subscription_action_filter_check" check ((action_filter = ANY (ARRAY['*'::text, 'INSERT'::text, 'UPDATE'::text, 'DELETE'::text])));

create unique index subscription_subscription_id_entity_filters_hash_key on realtime.subscription
  using btree (subscription_id, entity, realtime.filters_hash(filters), action_filter, COALESCE(selected_columns, '{}'::text[]));
