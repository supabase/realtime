-- An `in` filter at the 100-value maximum. 100 uuids put `filters` well past the 2704-byte btree
-- tuple limit, which the unique index on realtime.subscription used to hit at ~70 uuids (54000).
select 1 from pg_create_logical_replication_slot('realtime', 'wal2json', false);

-- The dump and the migrations must agree: the value index is gone, the digest index replaces it
select indexname, indexdef from pg_indexes
where schemaname = 'realtime' and tablename = 'subscription'
order by indexname;

create table public.notes(
    id int primary key,
    identifier uuid
);

alter table public.notes replica identity full;

-- `{uuid,uuid,...}` of n seeded uuids starting after `start`
create function in_list(start int, n int) returns text
    language sql
as $$
    select '{' || string_agg(seed_uuid(start + g)::text, ',' order by g) || '}'
    from generate_series(1, n) g
$$;

-- Same conflict target as the upsert in Extensions.PostgresCdcRls.Subscriptions
prepare upsert_subscription(uuid, text, text) as
    insert into realtime.subscription as x(subscription_id, entity, filters, claims, action_filter)
    values (
        $1,
        'public.notes',
        array[('identifier', 'in', $3, false)::realtime.user_defined_filter],
        jsonb_build_object('role', 'authenticated', 'email', $2, 'sub', seed_uuid(6)::text),
        '*'
    )
    on conflict
        (subscription_id, entity, realtime.filters_hash(filters), action_filter, coalesce(selected_columns, '{}'))
        do update set claims = excluded.claims
    returning subscription_id, claims ->> 'email' as email;

execute upsert_subscription(seed_uuid(5), 'first@example.com', in_list(1000, 100));

-- Resubscribing with the same filter updates the row rather than adding one
execute upsert_subscription(seed_uuid(5), 'second@example.com', in_list(1000, 100));

-- A different 100-value filter is its own row, for the same and for another subscription id
execute upsert_subscription(seed_uuid(5), 'other-filter@example.com', in_list(2000, 100));
execute upsert_subscription(seed_uuid(7), 'other-sub@example.com', in_list(2000, 100));

select
    subscription_id,
    claims ->> 'email' as email,
    octet_length(filters::text) > 2704 as over_old_btree_limit
from
    realtime.subscription
order by
    subscription_id, email;

-- 101 values is still rejected by subscription_check_filters
execute upsert_subscription(seed_uuid(5), 'too-many@example.com', in_list(3000, 101));

delete from realtime.subscription where claims ->> 'email' = 'other-filter@example.com';

select clear_wal();
insert into public.notes(id, identifier) values (1, seed_uuid(1100));
insert into public.notes(id, identifier) values (2, seed_uuid(2001));
insert into public.notes(id, identifier) values (3, seed_uuid(3001));

select
    rec::jsonb -> 'record' ->> 'id' as id,
    is_rls_enabled,
    subscription_ids,
    errors
from
   walrus
order by
    id;

deallocate upsert_subscription;
drop function in_list(int, int);
drop table public.notes;
select pg_drop_replication_slot('realtime');
truncate table realtime.subscription;
