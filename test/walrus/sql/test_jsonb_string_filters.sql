-- Filters on columns whose value does not survive the trip through jsonb.
--
-- apply_rls keeps each column value as `realtime.cast(<wal2json text>, type)`, which is
-- `to_jsonb(<text>::type)`. The filter path used `col.value #>> '{}'` to get the text back
-- for check_equality_op. That is not the inverse of to_jsonb for every type:
--
--   jsonb "matched"  ->  matched     (not valid JSON, check_equality_op raises)
--   jsonb null       ->  SQL NULL    (`value=not.is.null` silently drops the change)
--   text[] {a,b}     ->  ["a", "b"]  (not a valid array literal, check_equality_op raises)
--
-- A raise aborts apply_rls, and with it the whole list_changes poll. The slot does not
-- roll back with the transaction, so every change in that poll is lost, for every table
-- and subscriber of the tenant.

-- Keep errors to one line, so the transcript does not depend on PL/pgSQL line numbers.
\set VERBOSITY terse

select 1 from pg_create_logical_replication_slot('realtime', 'wal2json', false);

create table public.key_value_storage(
    key text primary key,
    value jsonb,
    doc json,
    tags text[]
);

-- The reported subscription: key=eq.abc,value=not.is.null
insert into realtime.subscription(subscription_id, entity, claims, filters)
values (
    seed_uuid(1),
    'public.key_value_storage',
    jsonb_build_object('role', 'authenticated', 'email', 'a@example.com', 'sub', seed_uuid(1)::text),
    array[
        ('key',   'eq', 'abc',  false),
        ('value', 'is', 'null', true)
    ]::realtime.user_defined_filter[]
);

select clear_wal();


-- ── jsonb values that survive the round trip ──

-- Expect 1 subscription: a JSON object.
insert into public.key_value_storage(key, value) values ('abc', '{"a": 1}');
select rec, subscription_ids, errors from walrus;

-- Expect 1 subscription: a JSON number.
update public.key_value_storage set value = '1' where key = 'abc';
select rec, subscription_ids, errors from walrus;

-- Expect 1 subscription: a JSON boolean.
update public.key_value_storage set value = 'true' where key = 'abc';
select rec, subscription_ids, errors from walrus;

-- Expect 0 subscriptions: SQL NULL is null.
update public.key_value_storage set value = null where key = 'abc';
select rec, subscription_ids, errors from walrus;


-- ── The report: a JSON string ──

-- Expect 1 subscription: the row matches key=eq.abc and its value is not null.
update public.key_value_storage set value = '"matched"' where key = 'abc';
select rec, subscription_ids, errors from walrus;

-- Expect 0 rows: the read above consumed the change.
select rec, subscription_ids, errors from walrus;


-- ── One bad value must not affect other rows ──

-- Expect 0 subscriptions: key 'other' fails key=eq.abc. check_equality_op still runs
-- for every filter of the subscription, so the value filter must not raise.
insert into public.key_value_storage(key, value) values ('other', '"x"');
select rec, subscription_ids, errors from walrus;

-- Expect 2 rows, 1 subscription on the first: a JSON string in the second change
-- must not fail the read, and with it the first change.
update public.key_value_storage set value = '{"a": 2}' where key = 'abc';
update public.key_value_storage set value = '"y"' where key = 'other';
select rec, subscription_ids, errors from walrus;


-- ── JSON null ──

-- Expect 1 subscription: JSON null is a value, the same as Postgres says below.
update public.key_value_storage set value = 'null' where key = 'abc';
select rec, subscription_ids, errors from walrus;
select 'null'::jsonb is not null as "postgres says";


-- ── An eq filter on a jsonb string ──

truncate table realtime.subscription;
delete from public.key_value_storage;
select clear_wal();

insert into realtime.subscription(subscription_id, entity, claims, filters)
values (
    seed_uuid(2),
    'public.key_value_storage',
    jsonb_build_object('role', 'authenticated', 'email', 'a@example.com', 'sub', seed_uuid(2)::text),
    array[('value', 'eq', '"matched"', false)]::realtime.user_defined_filter[]
);

-- Expect 1 subscription: value = '"matched"'::jsonb.
insert into public.key_value_storage(key, value) values ('abc', '"matched"');
select rec, subscription_ids, errors from walrus;


-- ── A json column ──

truncate table realtime.subscription;
delete from public.key_value_storage;
select clear_wal();

insert into realtime.subscription(subscription_id, entity, claims, filters)
values (
    seed_uuid(3),
    'public.key_value_storage',
    jsonb_build_object('role', 'authenticated', 'email', 'a@example.com', 'sub', seed_uuid(3)::text),
    array[('doc', 'is', 'null', true)]::realtime.user_defined_filter[]
);

-- Expect 1 subscription: a JSON string in a json column.
insert into public.key_value_storage(key, doc) values ('abc', '"matched"');
select rec, subscription_ids, errors from walrus;


-- ── An array column ──

truncate table realtime.subscription;
delete from public.key_value_storage;
select clear_wal();

insert into realtime.subscription(subscription_id, entity, claims, filters)
values (
    seed_uuid(4),
    'public.key_value_storage',
    jsonb_build_object('role', 'authenticated', 'email', 'a@example.com', 'sub', seed_uuid(4)::text),
    array[('tags', 'eq', '{a,b}', false)]::realtime.user_defined_filter[]
);

-- Expect 1 subscription: tags = '{a,b}'::text[].
insert into public.key_value_storage(key, tags) values ('abc', '{a,b}');
select rec, subscription_ids, errors from walrus;


drop table public.key_value_storage;
select pg_drop_replication_slot('realtime');
truncate table realtime.subscription;
