# SqlLogex

SqlLogex decides Postgres row-level security (RLS) policies in Elixir, without a query to the
database. It decides the policies that it can model. For all other policies, it tells the caller
to ask the database.

The library models Postgres only. The caller gives everything else as input: the table and its
columns, the roles, the session settings, and the functions that the library can inline. To inline
a call is to replace it with the body of the function. The library has no defaults for these
inputs. The tests use one example application for all of these inputs, see "The example of the
tests".

The library has no runtime dependencies, because NimbleParsec generates the parser at compile
time. Postgrex is a dependency of the tests only. The best overview of what the library does and
does not do is
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
profile that builds the known function is responsible for that. For example, the tests of the
library compare the known functions of the example profile with Postgres, see "Tests against
Postgres".

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
  evaluate a later argument while it plans the query. For an example, see the fallback body of
  `app.user_id()` in "The example of the tests".
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

## Comparing the library with your database

Before a caller uses the answers of the library in place of the database, it can compare the two
for its own policies. `SqlLogex.Differential` does this in tests.

The caller asks Postgres, and the library decides the same question. `compare/3` puts the two
answers in a class. `verify!/1` fails the test on a mismatch or a crash. A fallback does not fail,
because the caller then asks the database. `SqlLogex.Differential` does not connect to a database.

In this example, the test creates the policy in a transaction that rolls back. In the same
transaction, it reads the snapshot input and asks Postgres:

```elixir
env = SqlLogex.Env.new(%{"role" => "member", "app.team" => "red"}, %{"team" => {:text, "blue"}})

{input, postgres} =
  MyApp.Policies.rolled_back(conn, fn conn ->
    Postgrex.query!(conn, ~s(CREATE POLICY "own team" ON app.docs FOR SELECT TO member USING (team = app.team())), [])
    # The snapshot input, read as the application reads it, and the answer of Postgres
    {MyApp.Policies.snapshot_input(conn), MyApp.Policies.ask_postgres(conn, env, :read)}
  end)

library = SqlLogex.Differential.decide(SqlLogex.Snapshot.new(input, MyApp.Policies.profile()), env, :read)

[SqlLogex.Differential.compare(postgres, library, name: "a member reads a row of another team")]
|> SqlLogex.Differential.verify!()
```

`ask_postgres` asks as the application asks in production. If Postgres returns a value, the answer
is `{:ok, value}`. If Postgres raises an error, the answer is `{:error, sqlstate, code, message}`.

`SqlLogex.Differential.report/2` counts the matches and the fallbacks, and lists the most frequent
reasons of the fallbacks. The tests of this library use the same module, see "Tests against
Postgres".

## Running the tests

Run the library tests from this directory. Without a database, `mix test` excludes the tests
against Postgres.

```sh
mix test
```

Start to read at [test/sql_logex_test.exs](test/sql_logex_test.exs). SQL goes in and a value comes
out, for the most important cases. Each expected value is the value that Postgres 17 gives. The
other library tests cover one stage each.

The tests use one example application, see "The example of the tests". These modules in
`test/support` hold the example:

- `SqlLogex.Test.ExampleProfile`: the profile.
- `SqlLogex.Test.ExampleDatabase`: the table, the roles and the function bodies, as SQL for a
  plain Postgres.
- `SqlLogex.Test.ExamplePolicies`: the policies.
- `SqlLogex.Test.ExampleScenarios`: the scenarios of the tests against Postgres.

The fixtures in `test/fixtures/pg15` and `test/fixtures/pg17` hold the policies and the function
bodies as Postgres prints them. The tests against Postgres generate them.

### Tests against Postgres

These tests run SQL in Postgres and compare the answers of Postgres with the answers of the library.
Postgres is the oracle: its answer is the correct answer. The tests have the tag `:postgres`. If
`SQL_LOGEX_DATABASE_URL` is set, they run. Postgres 14 or later works.

[compose.yml](compose.yml) has one Postgres service for each major version that CI tests. Service
`postgres<major>` listens on port `54<major>`. Its data is in memory, so `docker compose down`
deletes it.

```sh
docker compose up -d --wait postgres17
export SQL_LOGEX_DATABASE_URL=postgres://postgres:postgres@localhost:5417/sql_logex_test

# about 15 s
mix test
SQL_LOGEX_REPORT=1 mix test test/postgres   # with a coverage report

docker compose down
```

The user in the URL must be a superuser, because the tests create roles and change them. If the
database does not exist, the tests create it and mark it with a comment. The tests refuse a
database without that mark, because they drop and create the schema `app` in it. The roles
`guest`, `member` and `admin` belong to the whole server. The tests create them if they do not
exist.

There are three test files:

- [test/postgres/expressions_test.exs](test/postgres/expressions_test.exs), Level 1, compares single
  expressions. It creates a policy with the expression as a policy author writes it, and reads
  back the `pg_get_expr` text. Postgres evaluates that text against a row, and the library
  evaluates the same text.
- [test/postgres/decisions_test.exs](test/postgres/decisions_test.exs), Level 2, compares
  `decide/3` with the row-level security of Postgres. A read is a `SELECT` of a probe row as the
  role. A write is an `INSERT` as the role, after the `SELECT` of the same call
  (`write_plans_select`). The scenarios are in `SqlLogex.Test.ExampleScenarios`. They include the
  decision table of `test/sql_logex/policy_set_test.exs`, so Postgres also checks what the unit
  tests expect.
- [test/postgres/fixtures_test.exs](test/postgres/fixtures_test.exs) makes sure that Postgres still
  prints the policies and the function bodies as in the fixture of its major version. With
  `SQL_LOGEX_WRITE_FIXTURES=1`, it writes that fixture again.

Levels 1 and 2 fail on a decided answer that is different from the answer of Postgres. They also
fail on a value where Postgres raised an error. They count fallbacks, but do not fail on them.
`SqlLogex.Differential` holds this comparison and the report. `SqlLogex.Test.Collector` adds two
checks for this library:

- Each reason of a fallback has a category in `SqlLogex.Reason`.
- Postgres agrees with each decision of the decision table of the unit tests.

The collector also adds report sections about the personal-team policies of the example: the
grid, the decision table and the planner-order cases.

For the current numbers, run the tests with `SQL_LOGEX_REPORT=1`. For each level, the report gives
the number of cases in each class, the classes by group, and the most frequent reasons of the
fallbacks. On Postgres 14 and 15, Level 2 has fewer cases, because one scenario needs
`GRANT ... WITH INHERIT`, which Postgres 16 added.

CI runs these tests against the three services of `compose.yml`. Postgres 17 runs with ICU as its
default collation provider, and Postgres 14 and 15 with libc. So the tests cover both providers.

On Postgres 14, run `mix test` and not `mix test --only postgres`. There is no pg14 fixture, so
`test_helper.exs` excludes the fixtures test. But `--only postgres` includes that test again.

## The example of the tests

The tests use one example application. It stores documents in the table `app.docs`. A document
belongs to a team (`team`) and has a kind (`kind`), for example `note` or `task`. Before a query,
the application sets the session settings that its policies read. `SqlLogex.Test.ExampleProfile`
is the profile of the example:

- `columns`: `team` and `kind`, both text.
- `roles`: `guest` and `member`. The `policy_roles` also include `admin`, a role that bypasses
  row-level security.
- `platform_schemas`: `app`. `platform_setting_prefixes`: `app.`. `platform_roles`: `admin` and
  `postgres`.
- `write_plans_select`: `true`.
- `functions`: the known definitions of the functions in the schema `app`.

The functions read the session settings:

- `app.team()` reads `app.team`, the team of the session.
- `app.user_id()` reads `app.user_id`, the id of the user, as a uuid.
- `app.user_role()` reads `app.user_role`, the role of the user.
- `app.claims()` reads `app.claims`, the claims of the user, as jsonb.

`app.user_id()` and `app.user_role()` have two known bodies each. The simple body reads only its
setting. The fallback body reads `sub` or `role` from the claims when its setting is empty. The
fallback body is a `COALESCE`, and the library evaluates every argument of a `COALESCE` (see
"Operators and expressions"). So if the claims contain `\u0000`, a call to the fallback body is a
fallback, also when the user id is set.

The env holds the settings `role`, `app.team`, `app.user_id`, `app.user_role`, `app.claims` and
`app.headers`, with the exact strings that the application passes to `set_config`.

## Status

### Done

- The parser, resolver, evaluator, policy combination and function fingerprints, with everything
  in "What it supports".
- The profile. All knowledge of a table or a platform is input from the caller.
- Measured against Postgres 14, 15 and 17 with the example profile, with 0 mismatches. CI runs
  these tests. See "Tests against Postgres".
- `SqlLogex.Differential`, for a caller that compares the library with its own database.

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

### Planned, or maybe

- Read function bodies instead of recognizing them. Today a profile gives each known body twice, as
  source text and as a tree. The reason is that the parser cannot read a raw body from `pg_proc`.
  But a caller can have Postgres print each body in the same canonical form as the policies. In a
  transaction that it rolls back, with `search_path = ''`, it creates a temporary view from the
  body. Then it reads the view back with `pg_get_viewdef`. The parser and resolver already read
  that text for a body like the fallback body of `app.user_id()`, and it evaluates correctly
  without a known function. Then a profile needs no list of known bodies, and simple helper
  functions of the policy author are covered too. It needs:
  - the `TEMP` privilege in the database (not known yet)
  - the same conditions as today for inlining a body: SQL language, stable, no `SECURITY DEFINER`,
    no `SET`, no arguments, a single `SELECT` without `FROM`
  - functions that call functions, resolved recursively, with a depth limit
  - a replacement for a setting that a known tree reads as NULL, because the caller never sets
    it. Read from the body, that setting is not in the env, so the call falls back. If the caller
    rules out database-level defaults, the env can hold such settings too.
- Evaluate more of SQL, driven by what real policies use. The fallback reasons that a caller
  records show which unsupported constructs cost coverage. So they pick what to add next, and a
  differential test against Postgres makes sure that each addition is correct. Candidates:
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
