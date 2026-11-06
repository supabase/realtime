# SqlLogex

SqlLogex decides Postgres row-level security (RLS) policies in Elixir, without a query to the
database. It decides the policies that it can model. For all other policies, it tells the caller
to ask the database.

The library models Postgres only. The caller gives everything else as input: the table and its
columns, the roles, the session settings, and the functions that the library can inline. To inline
a call is to replace it with the body of the function. The library has no defaults for these
inputs. This README uses Supabase Realtime as its worked example, see "Example: Supabase Realtime".

The library has no runtime dependencies, because NimbleParsec generates the parser at compile
time. The best overview of what the library does and does not do is
[test/sql_logex_test.exs](test/sql_logex_test.exs).

## How it works

Plain data goes in, and a plain result comes out. In this example, a table has a text column
`team`. The application sets the session setting `app.team`, and a policy compares the two with
the SQL function `app.team()`.

```elixir
import SqlLogex.KnownFunction

# The body of app.team(). The caller reads the real definition from pg_proc.
source = "select nullif(current_setting('app.team', true), '')::text"

# What the library knows about the table and the platform around it (see "Profiles")
profile = %SqlLogex.Profile{
  write_plans_select: true,
  columns: %{"team" => :text},
  # app.team() can be inlined: the source that the definition must match, and the body as a tree
  functions: [new("app", "team", "text", source, nullif(setting("app.team"), text("")))],
  roles: ["member"],
  policy_roles: ["member"],
  platform_roles: [],
  platform_schemas: ["app"],
  platform_setting_prefixes: ["app."]
}

snapshot =
  SqlLogex.Snapshot.new(
    %{
      rls_enabled: true,
      rls_forced: false,
      roles: %{"member" => %{bypass_rls: false, select: true, insert: true}},
      # As pg_policy has them. cmd is the command the policy is FOR, as polcmd's letter: "r" SELECT
      # (decides reads), "a" INSERT (writes), "*" ALL (both), "w" UPDATE and "d" DELETE (neither).
      # qual and with_check are pg_get_expr output, read with search_path = '' so every name is
      # qualified.
      policies: [
        %{name: "own team", cmd: "r", permissive: true, roles: ["member"],
          qual: "(team = app.team())", with_check: nil}
      ],
      # The definitions in the database of the functions in the platform schemas (see SqlLogex.Catalog)
      functions: [
        %{schema: "app", name: "team", language: "sql", volatility: "s", security_definer: false,
          config: nil, return_type: "text", source: source}
      ]
    },
    profile
  )

# The session settings, with the exact strings the caller passes to set_config, and the row to check
env = SqlLogex.Env.new(%{"role" => "member", "app.team" => "red"}, %{"team" => {:text, "red"}})

SqlLogex.decide(snapshot, env, :read)
#=> :allow | :deny | {:fallback, reason}
```

Here the answer is `:allow`. For a row with the team `"blue"`, the answer is `:deny`. For the role
`admin`, which is not in the profile, the answer is `{:fallback, {:role, :other}}`.

The pipeline has four stages, and each stage is a pure function:

1. `SqlLogex.Parser` parses the text that `pg_get_expr` prints into an AST. Text that it cannot
   read becomes `{:unsupported, raw}` in place, so parsing never fails.
2. `SqlLogex.Resolver` binds operators, casts and functions from an allowlist, and gives every node
   a type. It inlines the known functions of the profile, see "Inlined functions".
3. `SqlLogex.Eval` evaluates the result against the env, with three-valued logic (true, false and
   NULL), plus `{:unsupported, reason}`.
4. `SqlLogex.PolicySet` picks the policies that apply and combines them like `rowsecurity.c`.

`SqlLogex.Snapshot.new/2` runs steps 1 and 2 once per policy, so a decision is only steps 3 and 4.

Where Postgres raises an error for an input, the reason is
`{:unsupported, {:raises, sqlstate, detail}}`. An example is a cast to uuid of text that is not a
uuid. The decision is a fallback, and the database raises the error too.

### Profiles

A profile holds what the library knows about the table that it decides for, and about the platform
around that table. The platform is the system that runs the database. `SqlLogex.Snapshot.new/2` takes a profile, and
`SqlLogex.decide/3` reads it from the snapshot. `SqlLogex.Profile` has these fields:

- `write_plans_select`: the caller plans a `SELECT` of the table in the same call as the `INSERT`
  of a write. A write then also needs the `SELECT` grant. It falls back where a `SELECT` policy can
  raise an error (see `SqlLogex.PolicySet`). The only value is `true`, because only that case is
  measured against Postgres.
- `columns`: the columns of the checked row that a policy can read, with their types.
- `functions`: the functions that the library can inline, see "Inlined functions". You build them
  with `SqlLogex.KnownFunction`, so a profile does not depend on the internal form of `SqlLogex.IR`.
- `roles`: the roles that the library decides for.
- `policy_roles`: the roles that a policy can name, in addition to `public`. The library assumes
  that none of these roles is a member of another.
- `platform_roles`, `platform_schemas` and `platform_setting_prefixes`: the names that belong to
  the platform. A fallback reason keeps these names and hides all other names.

### Inlined functions

A policy can call a SQL function, and the policy author can change the body of that function at
any time. So the library inlines a call only under all of these conditions:

- The call has no arguments, and the function is in a platform schema of the profile.
- The snapshot has exactly one definition with that schema and name. Two definitions, for example
  overloads, make the call unsupported.
- The definition has `language` `sql`, `volatility` `s` (stable), `security_definer` `false` and
  `config` `nil`. So the function runs as the caller, with no settings of its own.
- The source has no comment, so a comment cannot hide a change.
- Apart from whitespace, the source is equal to the source of a known function of the profile with
  the same schema, name and return type (`SqlLogex.Catalog.normalize/1`).

Any other function call is a fallback. The only exception is the built-in
`current_setting(name, true)` with a literal name.

The library does not make sure that the tree of a known function does what its source does. The
profile that builds the known function is responsible for that. For example, Realtime tests its
known functions against Postgres, see "Tests against Postgres".

## What it supports

This section lists what the library can evaluate. Anything that is not in this list is a fallback.
The profile and the env decide which roles, columns, settings and functions a policy can use.

### Policies

- Commands: `SELECT` policies for reads, `INSERT` policies for writes, `ALL` policies for both. An
  `ALL` policy without `WITH CHECK` uses its `USING` expression for writes.
- Permissive policies are combined with OR, and restrictive policies with AND. With no permissive
  policy, the answer is deny.
- Policies `TO public` or to a role in the `policy_roles` of the profile. A policy for the
  operation that names any other role makes the decision a fallback.
- Callers with a role in the `roles` of the profile. The env gives the role as the setting `role`.
  Every other role is a fallback.
- If RLS is off or forced, or the role has `BYPASSRLS`, the decision is a fallback. If the role
  does not have the `SELECT` grant (reads) or the `INSERT` grant (writes), the decision is also a
  fallback.
- With `write_plans_select`, a write also needs the `SELECT` grant. If a `SELECT` policy that can
  apply is not fully supported, a write also falls back, see `SqlLogex.PolicySet`.
- Expressions up to 4 KB of `pg_get_expr` text.

### What a policy can read

- `current_setting(name, true)` with a literal name, for a setting in the env. A setting that is
  not in the env is a fallback, because only the caller knows its value.
- The columns of the profile, with their values from the row in the env.
- The known functions of the profile, see "Inlined functions".
- Scalar subselects without `FROM`, such as `(select app.team())`. A scalar subselect is a `SELECT`
  in parentheses that gives one value.

### Operators and expressions

- `AND`, `OR`, `NOT`, `IS NULL`, `IS NOT NULL`, with three-valued logic. An unsupported part
  anywhere in an `AND` or `OR` makes it a fallback, even `true OR <unsupported>`.
- `=` and `<>` on text and on uuid.
- `||` on two texts, and on a text and a uuid.
- `IN (...)` and `NOT IN (...)` over text. Postgres prints them as `= ANY (ARRAY[...])` and
  `<> ALL (ARRAY[...])`.
- `~` and `~*` with a literal pattern that has no regex metacharacters
  (`| * + ? ( ) . ^ $ \ [ {`). For `~*`, the text and the pattern must be ASCII.
- `jsonb ->> text` where the value is a string or a boolean. A missing key or JSON `null` gives
  NULL. Numbers, objects and arrays are a fallback.
- `COALESCE` over arguments of one type, and `NULLIF` on text. An unsupported argument anywhere
  makes `COALESCE` a fallback, even after a non-NULL argument. The reason is that Postgres can
  evaluate a later argument while it plans the query. For an example, see supabase/auth's
  `auth.uid()` in "The Realtime profile".
- Casts from text to uuid, jsonb and boolean, and from uuid to text. Literals of those types,
  `true`, `false` and typed `NULL`s.

### Values

- uuid input: everything that the Postgres function `uuid_in` accepts (either case, braces, a
  hyphen after any group of four digits). Anything else is a `{:raises, ...}` fallback.
- boolean input from text: ASCII only.
- jsonb input: up to 100 levels deep. For duplicate keys, the last value stays. `\u0000` is a
  `{:raises, ...}` fallback.
- Text compares byte by byte. That assumes a UTF-8 database with a deterministic default collation.
  Any `COLLATE` is a fallback.

### Not supported

These are examples of what is not supported. Each one is a fallback:

- subqueries with `FROM`, `EXISTS` and `CASE`
- `IS TRUE` and similar tests, `LIKE`, `ILIKE` and `!~`
- the jsonb operators `->`, `?` and `@>`
- number literals, and casts to `integer`, `numeric` or `json`
- columns that are not in the profile
- functions that the profile does not know, for example `lower()` and `now()`

## Running the tests

Run the library tests from this directory. They need no database.

```sh
mix test
```

Start to read at [test/sql_logex_test.exs](test/sql_logex_test.exs). SQL goes in and a value comes
out, for the most important cases. Each expected value is the value that Postgres 17 gives. The
other library tests cover one stage each.

The tests use the Realtime profile as their worked example. The library cannot depend on Realtime,
so [test/support/realtime_profile.ex](test/support/realtime_profile.ex) holds a copy of it,
`SqlLogex.Test.RealtimeProfile`. The fixtures in `test/fixtures/pg15` and `test/fixtures/pg17` hold
policies and function bodies as Postgres prints them. Realtime generates them.

The tests that run against Postgres are in Realtime, because they need a database. See "Tests
against Postgres".

## Example: Supabase Realtime

Supabase Realtime is the first user of the library. Realtime authorizes a join to a private channel
with the RLS policies on `realtime.messages`, in the database of the tenant. A tenant is one
customer project, with its own database. When many clients reconnect at once, that database becomes
the bottleneck. Many policies only compare the topic, the extension and JWT claims, and the library
can decide those instead. Today Realtime runs the library in shadow mode only, see "Shadow mode".

### The Realtime profile

`Realtime.Tenants.SqlLogexProfile`
([lib/realtime/tenants/sql_logex_profile.ex](../lib/realtime/tenants/sql_logex_profile.ex)) builds
the profile for `realtime.messages`:

- `columns`: `topic` and `extension`, both text. These are the columns of the probe row. The probe
  row is the row that Realtime checks in place of a real message.
- `roles`: `anon` and `authenticated`. The `policy_roles` also include `service_role`.
- `platform_schemas`: `auth` and `realtime`. `platform_setting_prefixes`: `request.` and
  `realtime.`. `platform_roles`: `service_role`, `postgres` and `supabase_admin`.
- `write_plans_select`: `true`, because `realtime.authorize` plans its `SELECT` in every call,
  write-only calls included.
- `functions`: these known definitions.

  | Function | Known definitions |
  |---|---|
  | `realtime.topic()` | the one Realtime installs |
  | `auth.uid()` | the supabase/postgres image's (reads `request.jwt.claim.sub`), supabase/auth's (also falls back to `sub` in the claims) |
  | `auth.role()` | the same two, for the role |
  | `auth.jwt()` | supabase/auth's |

  The older supabase/auth versions of `auth.uid()` are not known, so a call to one of them is a
  fallback.

The env holds the six settings that Realtime sets before the database check, with the exact
strings that Realtime sends: `role`, `realtime.topic`, `request.jwt.claims`,
`request.jwt.claim.sub`, `request.jwt.claim.role` and `request.headers`.

Two facts about the known functions show how a profile models a body:

- supabase/auth's `auth.jwt()` also reads `request.jwt.claim`, a setting that Realtime never sets.
  The tree of that known function reads it as NULL.
- supabase/auth's `auth.uid()` is a `COALESCE` that reads `request.jwt.claims` after
  `request.jwt.claim.sub`. If the claims contain `\u0000`, the call is a fallback. A set `sub` does
  not change that.

The library tests use a copy of this profile.
[test/realtime/tenants/sql_logex_profile_test.exs](../test/realtime/tenants/sql_logex_profile_test.exs)
makes sure that the two copies stay equal.

### Tests against Postgres

Run these from the Realtime root. They use the Realtime test database (supabase/postgres).

```sh
# about 25 s
mix test test/realtime/tenants/sql_logex_differential_test.exs
SQL_LOGEX_REPORT=1 mix test test/realtime/tenants/sql_logex_differential_test.exs   # coverage report
mix test test/realtime/tenants/sql_logex_fixtures_test.exs

# the Realtime side: profile, loader, cache, env, shadow mode, metrics
mix test test/realtime/tenants/sql_logex_{profile,loader,cache,env,shadow}_test.exs test/realtime/monitoring/prom_ex/plugins/sql_logex_test.exs
```

- The differential test,
  [test/realtime/tenants/sql_logex_differential_test.exs](../test/realtime/tenants/sql_logex_differential_test.exs),
  runs every case through Postgres and through the library. It fails on any decided answer that is
  different from the answer of Postgres, and on a value where Postgres raised an error. It counts
  fallbacks, but does not fail on them. Level 1 compares single expressions, written as customers
  write them. Level 2 compares `decide/3` with `realtime.authorize`.
- The fixtures test,
  [test/realtime/tenants/sql_logex_fixtures_test.exs](../test/realtime/tenants/sql_logex_fixtures_test.exs),
  makes sure that Postgres still prints the captured policies and function bodies
  (`test/fixtures/pg15`, `pg17`) in the form that the parser expects. With
  `SQL_LOGEX_WRITE_FIXTURES=1`, it writes them again.

These are the results with the Realtime profile, against Postgres 17 (`supabase/postgres:17.11`).
There are 0 mismatches:

- Level 1, expressions: 4018 cases, 2714 decided, 1304 fall back.
- Level 2, `decide/3` against `realtime.authorize`: 4308 cases, 2872 decided, 1436 fall back.
- A user-channel policy set (`topic = 'user:' || auth.uid()`, plus a literal `~*` policy): the
  library decides 800 of 816 `authenticated` joins with a uuid `sub` and an ASCII topic. The other
  16 have `\u0000` in a claim, which supabase/auth's `auth.uid()` reads.
- Postgres 14 and 15 give the same coverage, also with 0 mismatches (measured locally).

### Shadow mode

Shadow mode runs the library next to the current database check, behind the feature flag
`sql_logex_shadow` (off by default, per tenant). Realtime always uses the answer of the database,
and only compares the answer of the library with it. So shadow mode tests the library against real
policies without risk, but it does not reduce the load on the database.

- Where: in [lib/realtime/tenants/authorization.ex](../lib/realtime/tenants/authorization.ex),
  `get_read_authorizations/4` and `get_write_authorizations/4` call
  `Realtime.Tenants.SqlLogexShadow` after the database check. That is on the node with the database
  connection of the tenant, after the RPC to it. So the cache only lives on that one node.
- A snapshot per tenant: `Realtime.Tenants.SqlLogexLoader` reads these, in one transaction with
  `search_path = ''`:
  - the policies on `realtime.messages`
  - the definitions of `auth.uid()`, `auth.role()`, `auth.jwt()` and `realtime.topic()`
  - the RLS flags of the table
  - the grants and `BYPASSRLS` of `anon` and `authenticated`

  It asks the pool with `queue: false`. So a busy pool gives no snapshot, and the real check is not
  delayed.
- The cache: `Realtime.Tenants.SqlLogexCache` keeps the snapshot in Cachex, one cache per node.
  - It loads on the first check that needs it.
  - It does not cache a failed load.
  - Entries expire after `SQL_LOGEX_SNAPSHOT_CACHE_EXPIRATION_IN_MS` (5 minutes by default). A
    policy change takes that long to show.
- An env per check: `Realtime.Tenants.SqlLogexEnv` builds it from the `%Authorization{}` struct,
  with the exact strings that `set_conn_config/2` and `authorize/5` send to Postgres.
- One decision per extension: the `extension` of the probe row is different for each extension.
  So Realtime decides a read for each extension that `get_read_authorizations/4` checks
  (`broadcast`, and `presence` for a channel with presence on). It decides a write for the one extension in
  the request. `SqlLogex.decide/3` takes about 11 µs for the user-channel policies (measured
  locally).
- What it records: all of this runs in a detached task, so it cannot slow down or fail the real
  check.
  - Every decision emits `[:realtime, :tenants, :sql_logex, :shadow, :read | :write]` with an
    outcome: `:match`, `:mismatch`, `:fallback` or `:no_real_answer`. `:no_real_answer` means that
    the database check did not run (no connection, a timeout, a missing partition).
  - If Postgres raises an error while it evaluates the policies, that is a real answer. Examples
    are the SQLSTATE classes `22`, `42` and `P0`, like a sub that is not a uuid. So a decided answer
    against it is a `:mismatch`, as in the differential test. Realtime also logs every mismatch as
    a warning, with the SQLSTATE but not the error message.
  - The same metadata has a `reason` tag. For a `:fallback`, the tag is the category of the
    fallback (`SqlLogex.Reason.category/1`, a small fixed set like `:role`, `:function` or
    `:operator`). For the other outcomes, the tag is `:none`. So the metrics show which kinds of
    constructs cost coverage.
  - `:unavailable` means that no snapshot loaded. `:exception` means that the decision raised an
    exception.
  - `:timing` covers the whole shadow check, the cache lookup included.
  - `Realtime.PromEx.Plugins.SqlLogex` turns these into global metrics, with no tenant tag. The
    logs hold the tenant: mismatches, exceptions and unsupported policies.
- What the library cannot model: if some policies have parts that the library cannot model,
  Realtime logs `SqlLogexUnsupportedPolicies` once at `info` for each snapshot load. For each policy, the log gives the command, whether the policy is permissive, and the
  reasons (`SqlLogex.Snapshot.unsupported/1`). It has no policy names or SQL. That is once per
  tenant per cache expiry, and it shows which constructs to support next.

### Enforce mode

In enforce mode, Realtime uses every answer that the library decides. It asks the database only
on a fallback. Enforce mode is not built. It needs these changes:

- `:allow` and `:deny` fill the `Policies` struct. If any extension falls back, the simplest rule
  is to fall back for the whole call.
- The snapshot must be ready before a burst of reconnects arrives, and a join must never wait for a
  load. So Realtime loads it at the start of the database connection of the tenant
  (`Realtime.Tenants.Connect`), not on the first join. This load does not delay "ready".
- Realtime polls a fingerprint of everything that the snapshot reads (policies, function
  definitions, settings) every few minutes. Only a change of the fingerprint reloads the
  snapshot.
- The loader rules out the items in "Limits that the caller must cover", and the open decisions
  below have answers.

### Open items in Realtime

Not done:

- Enforce mode, see "Enforce mode".
- Role membership. The Realtime profile assumes that `anon`, `authenticated` and `service_role` are
  not members of each other. A tenant that runs `GRANT anon TO authenticated` gets a wrong answer
  for a policy `TO anon`. The loader must find that case (`pg_has_role`) and fall back. Shadow mode
  does not need it, because such a case shows as a mismatch.
- The other items in "Limits that the caller must cover". For Realtime, these are revoked `EXECUTE`
  on the known functions, revoked `USAGE` on `auth` or `realtime`, and user triggers on
  `realtime.messages`.
- Policy changes. Only the expiry of the cache notices them, after up to 5 minutes.

Planned, or maybe:

- Other columns of `realtime.messages` (`event`, `private`, `payload`). The profile can list them,
  and the env row must hold their values.
- Pushing parsed snapshots to other nodes.
- The row columns of postgres_changes.

Open decisions:

- `realtime.authorize` couples writes to reads. It plans its read statement on every call. If the
  role does not have `SELECT`, or a `SELECT` policy fails while Postgres plans it, a write check
  fails too. The transaction path does not do that. `decide(:write)` falls back where that
  can happen, because the Realtime profile sets `write_plans_select`. Fix it in a migration, or
  keep it.
- A missing daily partition makes the current database check fail, but the library decides.
  Realtime must choose which answer wins before enforce mode.
- Where enforce mode decides. There are two options:
  - On the node with the database connection of the tenant, where shadow mode runs. That saves the
    query, but not the RPC.
  - On the node that the client is connected to, before the RPC. That saves both, but needs a
    snapshot on every node with clients of that tenant.

## Status

### Done

- The parser, resolver, evaluator, policy combination and function fingerprints, with everything
  in "What it supports".
- The profile. All knowledge of a table or a platform is input from the caller.
- Measured against Postgres 14, 15 and 17 with the Realtime profile, with 0 mismatches. See "Tests
  against Postgres".

### Limits that the caller must cover

The snapshot does not model these items. Before a caller uses an answer in place of the answer of
the database, the caller must rule them out or fall back:

- Role membership. Policies match roles by inherited membership. The library assumes that none of
  the `policy_roles` is a member of another.
- Database-level or role-level defaults (`pg_db_role_setting`) for the settings that the policies
  read, or for `search_path`. The env holds the settings that the caller sets, not these defaults.
- A revoked `EXECUTE` on an inlined function, or a revoked `USAGE` on its schema.
- Triggers on the table.

### Not done

- `write_plans_select: false`, for a caller that runs only the `INSERT` of a write. Only `true` is
  measured against Postgres.
- No CI job runs the library tests yet. Only the Realtime suite runs, with the differential test.

### Planned, or maybe

- Read function bodies instead of recognizing them. Today a profile gives each known body twice, as
  source text and as a tree. The reason is that the parser cannot read a raw body from `pg_proc`.
  But a caller can have Postgres print each body in the same canonical form as the policies. In a
  transaction that it rolls back, with `search_path = ''`, it creates a temporary view from the
  body. Then it reads the view back with `pg_get_viewdef`. The parser and resolver already read
  that text for supabase/auth's `auth.uid()`, and it evaluates correctly without a known function.
  Then a profile needs no list of known bodies, and simple helper functions of the policy author
  are covered too. It needs:
  - the `TEMP` privilege in the database (not known yet)
  - the same conditions as today for inlining a body: SQL language, stable, no `SECURITY DEFINER`,
    no `SET`, no arguments, a single `SELECT` without `FROM`
  - functions that call functions, resolved recursively, with a depth limit
  - a replacement for a setting that a known tree reads as NULL, like `request.jwt.claim` in
    Realtime's `auth.jwt()`. Read from the body, that setting is not in the env, so the call falls
    back. If the caller rules out database-level defaults, the env can hold such settings too.
- Evaluate more of SQL, driven by what real policies use. The fallback reasons that a caller
  records show which unsupported constructs cost coverage, for example the metrics of Realtime's
  shadow mode. So they pick what to add next, and a differential test against Postgres makes sure
  that each addition is correct. Candidates:
  - numbers: integer literals, comparisons (`<`, `>`, ...) and casts like
    `(claims ->> 'level')::integer`. These are simple, but rare in the policies seen so far. JSON
    numbers read with `->>` and `numeric` need more work, because Postgres normalizes how they
    print (`1e2` becomes `100`, `1.50` keeps its scale).
  - more of jsonb: `->`, `?`, `@>`
  - `LIKE`, `IS TRUE` and similar tests, `lower()`
- Maybe: decide for real rows of a table, not only for one row that the caller builds. Only
  `{:setting, _}` and `{:column, _}` read data from outside the expression, so to bind a row is to
  fill in the env.

### Not planned

- Modeling the Postgres planner. Postgres short-circuits `AND` and `OR`, which means that it stops
  at the first part that decides the result. But it does that on the planned expression. The planner reorders
  policies and conditions, and planning already evaluates parts (constant folding, selectivity
  estimation). That changes between versions. So an unsupported part anywhere in an `AND`, `OR` or
  `COALESCE` makes the decision a fallback. Another part that alone decides the result does not
  change that. See `SqlLogex.Eval`.

### Open decisions

- The name. `sql_logex` is a working name. It was meant for the SQL parsing and evaluation only,
  not for the RLS specifics. Those can move to a separate library later, but not now.
