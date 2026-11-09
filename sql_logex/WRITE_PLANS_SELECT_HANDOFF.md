# Handoff: `write_plans_select` and the `SELECT` in `realtime.authorize`

This document records a discussion from 2026-11-06, for the agent that continues the work. Nobody
changed code during the discussion.

All paths start at the Realtime root, `/Users/eduardo/supa/realtime-lean`. The library is in
`sql_logex/`. The line numbers are from 2026-11-06 and can move.

## Summary

`write_plans_select: true` in a `SqlLogex.Profile` tells the library one fact about the caller. When
the caller asks "can this role write?", the same database call also runs a `SELECT` of the table as
that role. That `SELECT` does not change the answer, but it can raise an error. When it raises, the
write authorization fails.

`realtime.authorize` behaves like this because its `SELECT` step has no condition. The library was
made to match the function. Nobody changed the function for the flag.

The open question is whether to change `realtime.authorize` so that a write-only call skips the
`SELECT`. A write-only call asks only about writes. After that change, Realtime can use
`write_plans_select: false`, which the library does not implement yet.

## Decisions that belong to the user

Get an answer from the user to these questions before you write code:

1. Change `realtime.authorize`, or keep the current behavior. The library README lists this under
   "Open decisions".
2. If the function changes, how to roll out the profile change. See "Step 3".
3. How to order this change with the branch `fix/wal-authorize-calls`. See "Step 1".

## How Realtime authorizes a join

Realtime asks two separate questions for a private channel: can the user read, and can the user
write. `Realtime.Tenants.Authorization` (`lib/realtime/tenants/authorization.ex`) asks each question
in its own database call.

A read uses a probe row. A probe row is a test message that stands in for a real one. The
connection role inserts the probe row. RLS does not apply to that role, so the `INSERT` policies
have no effect. Then the role changes to the user's role, and a `SELECT` reads the probe row back.
If the row is visible, the user can read. So only the `SELECT` policies decide a read.

A write is an `INSERT` of a row as the user's role, in a savepoint. Error 42501
(`insufficient_privilege`) means that the user cannot write. When a `WITH CHECK` expression fails,
RLS raises this code.

Realtime has two code paths for these questions. The function path makes one call to
`realtime.authorize` (`read_policies_with_function`, `write_policies_with_function`). When the
feature flag `use_authorize_function` is on for the tenant, Realtime uses this path. The
transaction path runs separate statements in a transaction (`read_policies_with_transaction`,
`write_policies_with_transaction`). If `realtime.authorize` does not exist yet, Realtime also uses
the transaction path (`check_with_fallback`).

## What `realtime.authorize` does

The current body is in
`lib/realtime/tenants/repo/migrations/20261008120000_authorize_read_probes_single_partition.ex`. One
call does these steps:

1. As the connection role, it inserts one probe row per read extension (line 41).
2. It sets the role and the JWT settings of the user (line 45).
3. As the user's role, one `SELECT` reads the probe rows back (line 53).
4. As the user's role, it tries one `INSERT` per write extension. Each `INSERT` is in its own block
   that catches `insufficient_privilege` (lines 66 to 72).
5. It raises `RTA01` and catches it, which rolls back all the steps (line 79).

Realtime calls the function with only read extensions, or with only write extensions. On a
read-only call, step 4 runs zero times, so the `INSERT` policies do not matter.

Step 3 is not in a loop or an `if`. So on a write-only call, the `SELECT` still runs as the user's
role, with an empty list of probe ids.

## Why an empty `SELECT` can fail a write

The empty `SELECT` returns no rows. But Postgres still plans it. To plan a query is to prepare it
before it runs. Planning does three things that can raise an error:

1. It makes sure that the role has the `SELECT` privilege on the table.
2. It adds the `SELECT` policies of the role to the query.
3. It computes the constant parts of those policies.

Against Postgres 17, a write-only call raised in these cases, whatever the `INSERT` policies said:

1. The role has no `SELECT` grant: 42501.
2. A `SELECT` policy reads `realtime.messages` itself: 42P17 (infinite recursion).
3. A `SELECT` policy has a constant that raises, such as `1 / 0`: 22012.

Some `SELECT` policies raise only for a row, such as a cast of a `sub` that is not a uuid. Such a
policy did not raise on Postgres 17, because the query has no row. On a Multigres cluster it raised,
for example with `realtime.topic() = 't1' AND (SELECT auth.uid())::text = '...'`.

The function catches only `RTA01`, so these errors end the call. For the write, Realtime then
returns `{:error, :rls_policy_error, error}`, not "write denied" (`handle_policies_result` in
`lib/realtime/tenants/authorization.ex`). The transaction path for writes runs only the `INSERT`
(`check_write_policy`), so it does not have this problem.

For example, the `authenticated` role has an `INSERT` policy `WITH CHECK (true)`. Somebody runs
`REVOKE SELECT ON realtime.messages FROM authenticated`. The write authorization through
`realtime.authorize` now fails with "permission denied for table messages". The transaction path
still answers "allowed".

This is not the same as `INSERT ... RETURNING`. That statement applies the `SELECT` policies to the
new row, so a false `SELECT` policy fails the insert. In `realtime.authorize`, a `SELECT` policy
that is only false has no effect on a write.

## What the flag does in sql_logex

A fallback is the library answer "I cannot be sure, ask the database". The caller then asks
Postgres. A fallback is never a wrong answer. It only costs a query.

With `write_plans_select: true`, `SqlLogex.decide(snapshot, env, :write)` adds fallbacks where the
`SELECT` step can raise:

1. The role lacks the `SELECT` grant: `{:missing_grant, role, :select}`. See `grants/2` in
   `sql_logex/lib/sql_logex/policy_set.ex` (line 130).
2. A `SELECT` or `ALL` policy that can apply to the role has no `USING` expression, or has a node
   that the library does not support: `:select_policy_unsupported`. See `check_select_policies/4`
   (line 171).
3. For the row of the write, a supported `SELECT` policy gives an unsupported result. A policy
   that raises is in this group: `{:unsupported, reason}`. See `select_policy_fallback/3`.

If a policy is for `public`, for the role, or for a role that the profile does not model, it can
apply. A policy for a role that the profile does not model can apply through role membership.

The flag never changes an allow into a deny. Allow or deny for a write still comes only from the
`INSERT` and `ALL` policies. Reads do not change: `decide(:read)` uses only the `SELECT` and `ALL`
policies.

`true` is the only value. For the function path, it gives the same answers as Postgres. For the
transaction path, it is conservative: the library can fall back where Postgres gives an answer.

### Where the flag appears

- `sql_logex/lib/sql_logex/profile.ex`: the field documentation (line 10) and the type
  `write_plans_select: true` (line 31).
- `sql_logex/lib/sql_logex/policy_set.ex`: the moduledoc section "Writes that plan a SELECT also
  depend on the read policies", `grants/2` and `check_select_policies/4`.
- `sql_logex/lib/sql_logex/reason.ex`: the `:select_policy` class (line 17).
- `sql_logex/README.md`: the sections "Profiles", "Policies", the Realtime profile, "Open
  decisions" and "Not done".
- `lib/realtime/tenants/sql_logex_profile.ex`: the moduledoc (lines 6 to 13) and the field (line 49).
- `sql_logex/test/support/realtime_profile.ex`: a copy of the Realtime profile.
  `test/realtime/tenants/sql_logex_profile_test.exs` makes sure that the two stay equal.

### Tests of the flag

- Unit tests: `describe "a write also needs the SELECT policies to be modelled"` in
  `sql_logex/test/sql_logex/policy_set_test.exs` (line 733).
- Scenarios: `select_dependent_scenarios/0` in `sql_logex/test/support/realtime_scenarios.ex`
  (line 797).
- The plain Postgres oracle: `ask/4` in `sql_logex/test/postgres/decisions_test.exs`. It runs the
  probe `SELECT` in every call, as the function does. The oracle gives the correct answer.
- The Realtime oracle: `test/realtime/tenants/sql_logex_differential_test.exs`. It calls the real
  `realtime.authorize`.

## Proposed work

Do these steps only after the user answers the questions in "Decisions that belong to the user".

### Step 1: change `realtime.authorize` in a new tenant migration

Put the `SELECT` at line 53 inside an `if`, so that a write-only call skips it. Keep the `set_config` calls
outside the `if`, because the write inserts need the user's role. The probe `INSERT` at line 41
runs as the connection role, so it can stay as it is.

```sql
if cardinality(read_extensions) > 0 then
  visible_ids := array(
    select m.id
    from realtime.messages m
    where m.inserted_at = probe_inserted_at
      and m.id = any(probe_ids));
end if;

-- stays outside the if, see the note below
read_allowed := array(
  select p.id = any(visible_ids)
  from unnest(probe_ids) with ordinality as p(id, n)
  order by p.n);
```

Keep `read_allowed` equal to `'{}'`, not NULL, on a write-only call. `write_policies_with_function`
matches only `{:ok, {[], write_allowed}}`. Any other result is `{:unexpected_result, _}`, and
`fallback?/1` then sends every write to the transaction path with a warning log. An `array(...)`
over zero rows gives `'{}'`. So if the assignment above stays outside the `if`, it is correct.

Follow these rules for the migration:

1. Give it a timestamp newer than every tenant migration on `main`. On 2026-11-06 the newest one is
   `20261103130000_filter_on_raw_wal_values.ex`. Ecto runs an older pending migration last on
   existing tenants, so existing and new tenants can get different function bodies.
2. Add it to the list in `lib/realtime/tenants/migrations.ex` (near line 111).
3. End it with `ALTER FUNCTION ... OWNER TO supabase_realtime_admin`, as the two earlier
   migrations do.
4. Regenerate the tenant schema and the tenant dumps with `mise run tenant-dumps` (see `mise.toml`
   and `AGENTS.md`).

The branch `fix/wal-authorize-calls` is work in progress and is not merged. It also rewrites
`realtime.authorize`, in `20261007120000_authorize_without_wal.ex`. Its body keeps the same
`SELECT` with no condition. Ask the user how to order the two changes.

### Step 2: implement `write_plans_select: false` in sql_logex

1. In `profile.ex`, change the type to `boolean()` and update the field documentation.
2. In `policy_set.ex`, make `grants(:write, %Profile{write_plans_select: false})` return
   `[:insert]`. Make `check_select_policies/4` return `:ok` for `false`. Update the moduledoc.
3. In `reason.ex`, update the `:select_policy` class.
4. In `policy_set_test.exs`, add the `false` cases next to the `true` cases. A missing `SELECT`
   grant and a `SELECT` policy that the library does not support no longer cause a fallback.
5. If the profile value is `false` and the call has no reads, make `ask/4` in
   `decisions_test.exs` skip `@select_probes`. Run `select_dependent_scenarios/0` with both values.
6. In `README.md`, update "Profiles", "Policies" and "Not done".

The library code and its README describe Postgres and the profile only. Put Realtime facts in
`Realtime.Tenants.SqlLogexProfile`, or in the README sections that are labeled as the Realtime
example.

### Step 3: change the Realtime profile

Set `write_plans_select: false` in `Realtime.Tenants.SqlLogexProfile` and in
`sql_logex/test/support/realtime_profile.ex`. Update the moduledoc of `SqlLogexProfile` and the
Realtime sections of the README.

The value `false` is correct only on tenants that have the new function. Until every tenant runs
the Step 1 migration, some tenants keep the old function. On those tenants, the library then
decides where the old function raises. The differential test and shadow mode count each such case
as a mismatch. On tenants where `use_authorize_function` is off, `false` is already correct, because
the transaction path does not run the `SELECT`.

The user chooses one of these rollout options:

1. Keep `true` until every tenant runs the migration, then change to `false`.
2. Choose the profile value per tenant. The loader (`lib/realtime/tenants/sql_logex_loader.ex`, the
   `pg_proc` query at line 19) already reads function bodies. It can also read the body of
   `realtime.authorize`.
3. Change to `false` at once. The risk: during the rollout, the library and the old function give
   different answers in the cases of "Why an empty `SELECT` can fail a write".

## Rules for this work

- Do not commit. Leave all changes uncommitted, unless the user asks for a commit.
- Agree on the scope with the user before you write code.
- If you run `mix test` in the background, the tool can report it as done before it ends. Write an
  exit marker such as `EXIT=$?` at the end, and wait for it.
- Do not start two test runs at the same time.

## How to run the tests

These library tests need a Postgres superuser in `SQL_LOGEX_DATABASE_URL`. Run them from
`sql_logex/`:

```sh
docker run -d --rm --name sql-logex-pg -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:17
export SQL_LOGEX_DATABASE_URL=postgres://postgres:postgres@localhost:5432/sql_logex_test
mix test
SQL_LOGEX_REPORT=1 mix test test/postgres
```

Run the Realtime tests from the Realtime root:

```sh
mix test test/realtime/tenants/sql_logex_differential_test.exs
mix test test/realtime/tenants/sql_logex_{profile,loader,cache,env,shadow}_test.exs
```
