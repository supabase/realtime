# SqlLogex

Decides Postgres row-level security policies in Elixir, without asking the database, for the
policies it can model, and says "ask the database" for everything else.

Realtime authorizes a join to a private channel by running the tenant's RLS policies on
`realtime.messages` in the tenant's database. When many clients reconnect at once, that database
becomes the bottleneck. Many policies only compare the topic, the extension and JWT claims, and
those can be decided here instead. Nothing in Realtime calls this library yet.

**The rule:** every answer is either exactly what Postgres decides, or a fallback. A fallback is
never a guess, it means the caller runs today's database check. The evidence is the differential
test in Realtime,
[test/realtime/tenants/sql_logex_differential_test.exs](../test/realtime/tenants/sql_logex_differential_test.exs),
which runs thousands of cases through both Postgres and this library (see "Running the tests").

The best overview of what the library currently does and does not do is probably [test/sql_logex_test.exs](test/sql_logex_test.exs).

## How it works

Plain data in, plain result out. No Realtime, Ecto or Postgrex dependencies; NimbleParsec is
compile-time only.

```elixir
snapshot =
  SqlLogex.Snapshot.new(%{
    rls_enabled: true,
    rls_forced: false,
    roles: %{"authenticated" => %{bypass_rls: false, select: true, insert: true}},
    # pg_get_expr output, read with search_path = '' so every name is qualified
    policies: [
      %{name: "own channel", cmd: "r", permissive: true, roles: ["authenticated"],
        qual: "((realtime.topic() = ('user:'::text || auth.uid())) AND (extension = 'broadcast'::text))",
        with_check: nil}
    ],
    # the tenant's definitions of auth.uid(), realtime.topic(), ... (see SqlLogex.Catalog)
    functions: functions
  })

# The exact strings Realtime passes to set_config, and the probe row
env =
  SqlLogex.Env.new(
    %{"role" => "authenticated", "realtime.topic" => topic, "request.jwt.claims" => claims_json,
      "request.jwt.claim.sub" => sub, "request.jwt.claim.role" => "authenticated",
      "request.headers" => headers_json},
    %{"topic" => {:text, topic}, "extension" => {:text, "broadcast"}}
  )

SqlLogex.decide(snapshot, env, :read)
#=> :allow | :deny | {:fallback, reason}
```

The pipeline, each stage pure:

1. `SqlLogex.Parser` parses the text `pg_get_expr` prints into an AST. What it can't read becomes
   `{:unsupported, raw}` in place, so it never fails.
2. `SqlLogex.Resolver` binds operators, casts and functions from an allowlist and types every node.
   `auth.uid()`, `auth.jwt()`, `auth.role()` and `realtime.topic()` are inlined only if the
   tenant's definition matches a known body exactly (`SqlLogex.Catalog`), so a customised
   `auth.uid()` is never assumed to behave like ours.
3. `SqlLogex.Eval` evaluates against the env: three-valued logic, plus `{:unsupported, reason}`.
4. `SqlLogex.PolicySet` picks the policies that apply and combines them like `rowsecurity.c`.

Steps 1 and 2 run once per snapshot, so a decision is only step 3 and 4.

Where Postgres raises for an input (a `sub` that isn't a uuid, claims with `\u0000`, ...), the
reason is `{:unsupported, {:raises, sqlstate, detail}}`: a fallback, and the database raises too.

## What it supports

Anything not listed here is a fallback.

**Policies**

- Commands: `SELECT` policies for reads, `INSERT` policies for writes, `ALL` policies for both.
  An `ALL` policy without `WITH CHECK` uses its `USING` expression for writes.
- Permissive policies are OR'd, restrictive ones AND'd. With no permissive policy the answer is
  deny.
- Policies `TO public`, `anon`, `authenticated` or `service_role`. A policy for the operation that
  names any other role makes the decision a fallback.
- Callers with the role `anon` or `authenticated`. Every other role falls back, `service_role`
  included.
- Falls back when RLS is off or forced, the role has `BYPASSRLS`, or lacks the `SELECT` (reads) or
  `INSERT` and `SELECT` (writes) grant. A write also falls back when a `SELECT` policy that may
  apply isn't fully supported, see "Open decisions".
- Expressions up to 4 KB of `pg_get_expr` text.

**What a policy can read**

- `current_setting(name, true)` with a literal name, for the six settings Realtime sets: `role`,
  `realtime.topic`, `request.jwt.claims`, `request.jwt.claim.sub`, `request.jwt.claim.role` and
  `request.headers`.
- The columns `topic` and `extension` of the row being checked.
- These functions, without arguments, and only if the tenant's definition is one of the known ones
  apart from whitespace (`SqlLogex.Catalog`):

  | Function | Known definitions |
  |---|---|
  | `realtime.topic()` | the one Realtime installs |
  | `auth.uid()` | the supabase/postgres image's (reads `request.jwt.claim.sub`), supabase/auth's (also falls back to `sub` in the claims) |
  | `auth.role()` | the same two, for the role |
  | `auth.jwt()` | supabase/auth's |

  Anything else, comments, `SECURITY DEFINER` or a `SET` option included, makes the call a
  fallback.
- Scalar subselects without `FROM`, such as `(select auth.uid())`.

**Operators and expressions**

- `AND`, `OR`, `NOT`, `IS NULL`, `IS NOT NULL`, with SQL's three-valued logic. An unsupported part
  anywhere in an `AND` or `OR` makes it a fallback, even `true OR <unsupported>`.
- `=` and `<>` on text and on uuid.
- `||` on text, and text with a uuid (`'user:' || auth.uid()`).
- `IN (...)` and `NOT IN (...)` over text, which Postgres prints as `= ANY (ARRAY[...])` and
  `<> ALL (ARRAY[...])`.
- `~` and `~*` with a literal pattern, one without regex metacharacters (`| * + ? ( ) . ^ $ \ [ {`).
  For `~*`, the topic and the pattern must be ASCII.
- `jsonb ->> text` where the value is a string or a boolean. A missing key or JSON `null` gives
  NULL. Numbers, objects and arrays fall back.
- `COALESCE` over arguments of one type, and `NULLIF` on text. An unsupported argument anywhere
  makes `COALESCE` a fallback, even after a non-NULL one: Postgres can evaluate a later argument
  while planning. So with supabase/auth's `auth.uid()`, claims containing `\u0000` fall back even when
  `sub` is set.
- Casts from text to uuid, jsonb and boolean, and from uuid to text. Literals of those types,
  `true`, `false` and typed `NULL`s.

**Values**

- uuid input: everything Postgres's `uuid_in` accepts (either case, braces, a hyphen after any
  group of four digits). Anything else is a `{:raises, ...}` fallback.
- boolean input from text: ASCII only.
- jsonb input: up to 100 levels deep, duplicate keys keep the last value, `\u0000` is a
  `{:raises, ...}` fallback.
- Text compares byte by byte. That assumes a UTF-8 database with a deterministic default
  collation; any `COLLATE` falls back.

**Not supported**, for example: subqueries with `FROM`, `EXISTS`, `CASE`, `IS TRUE` and friends,
`LIKE`/`ILIKE`, `!~`, `->`, `?`, `@>`, number literals, casts to `integer`, `numeric` or `json`,
other columns of `realtime.messages` (`event`, `private`, `payload`), and any other function
(`lower()`, `now()`, `auth.email()`, ...).

## Running the tests

```sh
cd sql_logex && mix test          # the library alone, no database

# from the Realtime root, against the test database (supabase/postgres), about 25 s
mix test test/realtime/tenants/sql_logex_differential_test.exs
SQL_LOGEX_REPORT=1 mix test test/realtime/tenants/sql_logex_differential_test.exs   # coverage report
mix test test/realtime/tenants/sql_logex_fixtures_test.exs
```

- **[test/sql_logex_test.exs](test/sql_logex_test.exs)** is the place to start reading: SQL in,
  value out, for the cases that matter most, each checked against Postgres 17. The other library
  tests cover one stage each.
- **The differential test**,
  [test/realtime/tenants/sql_logex_differential_test.exs](../test/realtime/tenants/sql_logex_differential_test.exs),
  runs every case through Postgres and through this library and fails on any decided answer that
  differs, including a value where Postgres raised. Fallbacks are counted, not failed. Level 1
  compares single expressions, written as customers write them, Level 2 compares `decide/3` with
  `realtime.authorize`. It lives in Realtime because it needs Realtime's test databases and
  migrations.
- **The fixtures test**,
  [test/realtime/tenants/sql_logex_fixtures_test.exs](../test/realtime/tenants/sql_logex_fixtures_test.exs),
  checks that Postgres still prints the captured policies and function bodies
  (`test/fixtures/pg15`, `pg17`) the way the parser expects. `SQL_LOGEX_WRITE_FIXTURES=1`
  rewrites them.

## Integrating into Realtime's channel authorization

Nothing of this exists yet; it is what the integration needs, in order.

1. **Where.** At the top of `get_read_authorizations/4` and `get_write_authorizations/4` in
   [lib/realtime/tenants/authorization.ex](../lib/realtime/tenants/authorization.ex), before the
   rate counter and the RPC to the node that holds the tenant's database connection. A decided
   join then costs neither the RPC nor the query.
2. **A snapshot per tenant, per node.** Load the policies on `realtime.messages`, the definitions
   of `auth.uid()`, `auth.role()`, `auth.jwt()` and `realtime.topic()`, the table's RLS flags and
   the grants of `anon` and `authenticated`, with `search_path = ''`. The queries are in the
   differential test (`@policies_query`, `@functions_query`, `@table_query`, `@roles_query`),
   and its `load_snapshot_input/1` turns their rows into the map `SqlLogex.Snapshot.new/1`
   takes. Build the snapshot once and cache it: it parses and resolves every policy, about
   0.6 ms for five policies (measured locally). The loader also has to rule out what "Not done"
   lists.
3. **An env per join**, from the `%Authorization{}` struct, with the exact strings
   `set_conn_config/2` and `authorize/5` send to Postgres:

   ```elixir
   settings = %{
     "role" => auth.role,
     "realtime.topic" => auth.topic,
     "request.jwt.claims" => Jason.encode!(auth.claims),
     "request.jwt.claim.sub" => auth.sub,
     "request.jwt.claim.role" => auth.role,
     "request.headers" => auth.headers |> Map.new() |> Jason.encode!()
   }

   env = SqlLogex.Env.new(settings, %{"topic" => {:text, auth.topic}, "extension" => {:text, "broadcast"}})
   ```
4. **One decision per extension.** The probe row's `extension` differs, so a read is decided for
   each extension `get_read_authorizations/4` checks (`broadcast`, and `presence` when presence
   is enabled), and a write for the one extension asked. `SqlLogex.decide/3` takes about 11 µs
   for the user-channel policies (measured locally).
5. **Using the answer.** `:allow` and `:deny` fill the `Policies` struct. Any `{:fallback, _}`
   means today's check; the simplest rule is to fall back for the whole call if any extension
   does.
6. **Shadow mode first, then enforce.** In shadow mode the library runs next to today's check in
   production, but the database's answer is always the one used. The two are compared, and
   telemetry records how often the library decided, whether it agreed (logging every
   mismatch), and how long each took. This checks the library against every tenant's real
   policies without risk, but saves no load, since the database is still asked every time.
   Enforce mode then uses the library's answer whenever it decided, and asks the database only
   on a fallback. The open decisions below (the write coupling of `realtime.authorize`, a
   missing partition) need answers before enforcing.

## Status

### Done

- The library: parser, resolver, evaluator, policy combination, function fingerprints, with
  everything in "What it supports".
- Measured against Postgres 17 (`supabase/postgres:17.11`) by the differential test, 0 mismatches:
  - Level 1, expressions: 4018 cases, 2714 decided, 1304 fall back.
  - Level 2, `decide/3` vs `realtime.authorize`: 4308 cases, 3048 decided, 1260 fall back.
  - A user-channel policy set (`topic = 'user:' || auth.uid()`, plus a literal `~*` policy):
    800 of 816 `authenticated` joins with a uuid `sub` and an ASCII topic are decided. The rest
    have `\u0000` in a claim, which supabase/auth's `auth.uid()` reads.

### Not done

- **Integration.** No loader, no cache, no shadow mode, no enforcement. See "Integrating into
  Realtime's channel authorization" for what it needs.
- **Role membership.** Policies match roles by inherited membership. The snapshot doesn't record
  memberships between `anon`, `authenticated` and `service_role`, so a tenant that runs
  `GRANT anon TO authenticated` gets a wrong answer for a policy `TO anon`. The loader has to check
  for that (`pg_has_role`) and fall back.
- **Other things the loader has to rule out:** database- or role-level defaults
  (`pg_db_role_setting`) for the settings the policies read or for `search_path`, revoked `EXECUTE`
  on the inlined functions or `USAGE` on `auth`/`realtime`, and user triggers on
  `realtime.messages`.
- **Policy changes.** Nothing notices them yet.
- No CI job runs the library's own tests yet (only the Realtime suite runs the differential test).

### Planned, or maybe

- A per-tenant loader and cache that loads a tenant's snapshot once per node, not once per join,
  with a cheap fingerprint poll (policies and function definitions) to notice changes. After a
  deploy every node starts with a cold cache, so a burst of joins must trigger one load, not one
  per join.
- A shadow mode before the RPC in `get_read_authorizations`/`get_write_authorizations`, behind a
  feature flag: the database check stays the answer, the library is compared with it, and
  telemetry records coverage, mismatches and timing (the Scientist pattern).
- Then an enforce mode, which uses a decided answer and falls back otherwise.
- **Reading function bodies instead of recognising them.** Today `SqlLogex.Catalog` only inlines
  the few bodies of `auth.uid()`, `auth.role()`, `auth.jwt()` and `realtime.topic()` that
  Supabase ships, matched by exact text, because the parser can't read a raw body from `pg_proc`.
  The loader could have Postgres print each body in the same canonical form as the policies: in
  a transaction that is rolled back, with `search_path = ''`, create a temporary view from the
  body and read it back with `pg_get_viewdef`. The parser and resolver already read that text
  for supabase/auth's `auth.uid()`, and it evaluates correctly without the catalog. That would
  remove the list of known bodies and also cover simple helper functions of a tenant's own. It
  needs:
  - the `TEMP` privilege in tenant databases (not checked yet);
  - the same conditions as today for inlining a body: SQL language, stable, no
    `SECURITY DEFINER`, no `SET`, no arguments, a single `SELECT` without `FROM`;
  - functions that call functions resolved recursively, with a depth limit;
  - a replacement for one assumption the catalog makes. `auth.jwt()` reads
    `request.jwt.claim`, a setting Realtime never sets, and the catalog treats it as NULL. Read
    dynamically, it would fall back as an unknown setting unless the env models settings
    Realtime never sets, which in turn relies on the loader ruling out database-level defaults.
- **Evaluating more of SQL, driven by what real policies use.** Shadow mode's fallback reasons
  show which unsupported constructs actually cost coverage, so they pick what to add next, and
  the differential test checks each addition against Postgres. Candidates:
  - numbers: integer literals, comparisons (`<`, `>`, ...) and casts like
    `(auth.jwt() ->> 'level')::integer`. Straightforward, though rare in channel policies. JSON
    numbers read with `->>` and `numeric` take more, as Postgres normalises how they print
    (`1e2` becomes `100`, `1.50` keeps its scale);
  - more of jsonb: `->`, `?`, `@>`;
  - `LIKE`, `IS TRUE` and friends, `lower()`, other columns of `realtime.messages`.
- Maybe: pushing parsed snapshots to other nodes, the row columns of postgres_changes and live
  queries (only `{:setting, _}` and `{:column, _}` read the outside world, so binding a row is
  filling in the env).

### Not planned

- **Modelling the Postgres planner.** Postgres short-circuits `AND`/`OR`, but on the planned
  expression: policies and conditions are reordered, and planning already evaluates parts (constant
  folding, selectivity estimation). That changes between versions, so an unsupported part anywhere
  in an `AND`, `OR` or `COALESCE` makes the decision a fallback, even when another part could
  decide it. See `SqlLogex.Eval`.

### Open decisions

- **The name.** `sql_logex` is a working name.
  - most particularly the name was meant just for the SQL parsing/execution and not all of the RLS specifics, may be worth splitting out later but not now
- **`realtime.authorize` couples writes to reads.** It plans its read statement on every call, so
  a write check fails if the role lacks `SELECT` or a `SELECT` policy fails while planning. The
  transaction path doesn't do that. `decide(:write)` falls back where that could happen (see
  `SqlLogex.PolicySet`). Fix it in a migration, or keep it.
- **A missing daily partition** makes today's database check fail, where this library would
  decide. Which answer wins is decided when integrating.
