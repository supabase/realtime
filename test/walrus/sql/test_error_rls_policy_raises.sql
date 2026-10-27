/*
Tests that an RLS policy raising for one subscription's claims is contained to that subscription:
- Two authenticated subscribers, one carrying app_metadata.app_id = "null", which the policy casts to uuid and raises
- One anon subscriber on a policy that always passes
- Expected: both healthy subscribers receive the record, the poisoned one gets an Error 500 row with no record
*/

select 1 from pg_create_logical_replication_slot('realtime', 'wal2json', false);

create table public.notes(
    id int primary key,
    body text
);

create policy rls_note_app_id
on public.notes
to authenticated
using (
    coalesce(
        ((current_setting('request.jwt.claims', true)::jsonb -> 'app_metadata' ->> 'app_id')::uuid)::text,
        'no-app-id'
    ) is not null
);

create policy rls_note_anon
on public.notes
to anon
using (true);

alter table public.notes enable row level security;

insert into realtime.subscription(subscription_id, entity, claims)
values
    (
        seed_uuid(1),
        'public.notes',
        jsonb_build_object('role', 'authenticated', 'sub', seed_uuid(4)::text)
    ),
    (
        seed_uuid(2),
        'public.notes',
        jsonb_build_object('role', 'authenticated', 'sub', seed_uuid(5)::text, 'app_metadata', jsonb_build_object('app_id', 'null'))
    ),
    (
        seed_uuid(3),
        'public.notes',
        jsonb_build_object('role', 'anon')
    );

select clear_wal();
insert into public.notes(id, body) values (1, 'hello');

select
    rec,
    is_rls_enabled,
    subscription_ids,
    errors
from
   walrus;


drop table public.notes;
select pg_drop_replication_slot('realtime');
truncate table realtime.subscription;
