-- Filters whose stored value no longer fits the type of their column.
--
-- subscription_check_filters checks a filter value against the column type once, when the
-- subscription is created. A later schema change, such as renaming an enum value or changing
-- the column type, can leave the stored value invalid for the column. check_equality_op casts
-- the value to the current type of the column for every change to the table, so it raised.
-- A raise aborts apply_rls, and with it the whole list_changes poll. The slot does not roll
-- back with the transaction, so every change in that poll was lost, for every table and
-- subscriber of the tenant.
--
-- A filter that can no longer be evaluated now never matches. Its subscription stops getting
-- changes to that table, and every other change is still delivered.

-- Keep errors to one line, so the transcript does not depend on PL/pgSQL line numbers.
\set VERBOSITY terse

select 1 from pg_create_logical_replication_slot('realtime', 'wal2json', false);

create type public.order_status as enum ('pending', 'shipped');

create table public.orders(
    id int primary key,
    status public.order_status,
    ref text,
    paid boolean
);

create table public.notes(
    id int primary key,
    body text
);

insert into realtime.subscription(subscription_id, entity, claims, filters)
select
    seed_uuid(seed),
    entity::regclass,
    jsonb_build_object('role', 'authenticated', 'email', 'a@example.com', 'sub', seed_uuid(seed)::text),
    filters
from
    (
        values
            (1, 'public.orders', array[('status', 'eq', 'pending', false)]::realtime.user_defined_filter[]),
            (2, 'public.orders', array[('status', 'eq', 'pending', true)]::realtime.user_defined_filter[]),
            (3, 'public.orders', array[('status', 'in', '{pending,shipped}', false)]::realtime.user_defined_filter[]),
            (4, 'public.orders', array[('ref', 'eq', 'abc', false)]::realtime.user_defined_filter[]),
            (5, 'public.orders', array[('paid', 'is', 'true', false)]::realtime.user_defined_filter[]),
            (6, 'public.orders', null),
            (7, 'public.notes', null)
    ) f(seed, entity, filters);

select clear_wal();


-- ── Before any schema change ──

-- Expect subscriptions 1, 3, 4, 5 and 6. Subscription 2 is status=not.eq.pending.
insert into public.orders values (1, 'pending', 'abc', true);
select rec, subscription_ids, errors from walrus;


-- ── An enum value the filters use is renamed ──

alter type public.order_status rename value 'pending' to 'queued';

-- Expect subscriptions 4, 5 and 6 for the order and 7 for the note. 'pending' is no longer a
-- value of the type, so subscriptions 1, 2 and 3 do not match.
insert into public.orders values (2, 'queued', 'abc', true);
insert into public.notes values (1, 'first');
select rec, subscription_ids, errors from walrus;


-- ── Filtered columns change type ──

alter table public.orders alter column ref type integer using null;
alter table public.orders alter column paid type text using paid::text;

-- Expect subscription 6 for the order and 7 for the note. 'abc' is not an integer, and IS TRUE
-- needs a boolean, so subscriptions 4 and 5 do not match either.
insert into public.orders values (3, 'shipped', 7, 'true');
insert into public.notes values (2, 'second');
select rec, subscription_ids, errors from walrus;


-- ── check_equality_op on its own ──

create domain public.short_code as text check (length(value) <= 3);

-- Expect false for each, because the value cannot be read as the type, the domain constraint
-- rejects it, or IS TRUE needs a boolean.
select realtime.check_equality_op('eq', 'public.order_status', 'queued', 'pending', false);
select realtime.check_equality_op('eq', 'public.order_status', 'queued', 'pending', true);
select realtime.check_equality_op('in', 'public.order_status', 'queued', '{pending,queued}', false);
select realtime.check_equality_op('eq', 'integer', '7', 'abc', false);
select realtime.check_equality_op('eq', 'public.short_code', 'abc', 'abcd', true);
select realtime.check_equality_op('is', 'text', 'true', 'true', false);

-- Expect true: a value that still fits the type is compared as before.
select realtime.check_equality_op('eq', 'public.order_status', 'queued', 'queued', false);
select realtime.check_equality_op('in', 'public.order_status', 'queued', '{queued,shipped}', false);


drop table public.orders;
drop table public.notes;
drop type public.order_status;
drop domain public.short_code;
select pg_drop_replication_slot('realtime');
truncate table realtime.subscription;
