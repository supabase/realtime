/*
Tests that char(n) and bit(n) values keep their full length.

A cast to the bare type name means char(1) or bit(1), which truncated every value: the RLS
visibility check looked up a one-character primary key and dropped the INSERT and UPDATE, the
DELETE sent a one-character old_record, and filters compared truncated values.
*/

select 1 from pg_create_logical_replication_slot('realtime', 'wal2json', false);


create table public.notes(
    id char(21) primary key,
    country char(2),
    flags bit(5),
    tags char(3)[]
);

create policy rls_notes_select
on public.notes
to authenticated
using (true);

alter table public.notes enable row level security;


insert into realtime.subscription(subscription_id, entity, claims, filters)
values
    (
        seed_uuid(1),
        'public.notes',
        jsonb_build_object('role', 'authenticated', 'sub', seed_uuid(1)::text),
        array[('country', 'eq', 'GB', false)::realtime.user_defined_filter]
    ),
    (
        seed_uuid(2),
        'public.notes',
        jsonb_build_object('role', 'authenticated', 'sub', seed_uuid(2)::text),
        array[('country', 'in', array['GB', 'US']::text, false)::realtime.user_defined_filter]
    ),
    (
        seed_uuid(3),
        'public.notes',
        jsonb_build_object('role', 'authenticated', 'sub', seed_uuid(3)::text),
        null
    );


insert into public.notes(id, country, flags, tags)
values
    ('V1StGXR8_Z5jdHi6B-myT', 'GB', '10110', '{abc,de}'), -- matches both filters
    ('Uakgb_J5m9g-0JDMbcJqL', 'GR', '00001', '{xyz}');    -- shares only the first letter

select
    rec::jsonb ->> 'type' as type,
    rec::jsonb -> 'record' as record,
    rec::jsonb -> 'old_record' as old_record,
    subscription_ids,
    errors
from
   walrus;


update public.notes set flags = '01001' where id = 'V1StGXR8_Z5jdHi6B-myT';

select
    rec::jsonb ->> 'type' as type,
    rec::jsonb -> 'record' as record,
    rec::jsonb -> 'old_record' as old_record,
    subscription_ids,
    errors
from
   walrus;


delete from public.notes where id = 'V1StGXR8_Z5jdHi6B-myT';

select
    rec::jsonb ->> 'type' as type,
    rec::jsonb -> 'record' as record,
    rec::jsonb -> 'old_record' as old_record,
    subscription_ids,
    errors
from
   walrus;

drop table public.notes;
select pg_drop_replication_slot('realtime');
truncate table realtime.subscription;
