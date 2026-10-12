# SqlLogex

Decides Postgres row-level security policies in Elixir, without asking the database, for the
policies it can model, and says "ask the database" for everything else.

Realtime authorizes a join to a private channel by running the tenant's RLS policies on
`realtime.messages` in the tenant's database. When many clients reconnect at once, that database
becomes the bottleneck. Many policies only compare the topic, the extension and JWT claims, and
those can be decided here instead. Realtime runs this library in shadow mode, behind a feature
flag: its answer is compared with the database's, never used (see "In Realtime").

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
    # As pg_policy has them. cmd is the command the policy is FOR, as polcmd's letter: "r" SELECT
    # (decides reads), "a" INSERT (writes), "*" ALL (both), "w" UPDATE and "d" DELETE (neither).
    # qual and with_check are pg_get_expr output, read with search_path = '' so every name is
    # qualified.
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

Fallback reasons never contain policy text, names from the tenant's schemas or input values, so
they can be logged. A function or type outside `pg_catalog`, `auth` and `realtime` is
`:other_schema`, a policy's unparsed part is only its first keyword, and policy names aren't in
any reason.

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

# the Realtime side: loader, cache, env, shadow mode, metrics
mix test test/realtime/tenants/sql_logex_{loader,cache,env,shadow}_test.exs test/realtime/monitoring/prom_ex/plugins/sql_logex_test.exs
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

## In Realtime

Shadow mode runs the library next to today's database check, behind the feature flag
`sql_logex_shadow` (off by default, per tenant). The database's answer is always the one used.
The library's answer is only compared with it, so shadow mode checks the library against real
policies without risk, but saves no load.

- **Where.** In [lib/realtime/tenants/authorization.ex](../lib/realtime/tenants/authorization.ex),
  `get_read_authorizations/4` and `get_write_authorizations/4` call
  `Realtime.Tenants.SqlLogexShadow` after the database check. That is on the node holding the
  tenant's database connection, after the RPC to it. So the cache only ever lives on that one node.
- **A snapshot per tenant.** `Realtime.Tenants.SqlLogexLoader` reads, in one transaction with
  `search_path = ''`:
  - the policies on `realtime.messages`
  - the definitions of `auth.uid()`, `auth.role()`, `auth.jwt()` and `realtime.topic()`
  - the table's RLS flags
  - the grants and `BYPASSRLS` of `anon` and `authenticated`

  It asks the pool with `queue: false`, so a busy pool means no snapshot rather than a delayed
  real check.
- **The cache.** `Realtime.Tenants.SqlLogexCache` keeps the snapshot in Cachex, one cache per node.
  - It loads on the first check that needs it.
  - It doesn't cache a failed load.
  - Entries expire after `SQL_LOGEX_SNAPSHOT_CACHE_EXPIRATION_IN_MS` (5 minutes by default). That
    is also how long a policy change takes to show.
- **An env per check.** `Realtime.Tenants.SqlLogexEnv` builds it from the `%Authorization{}`
  struct, with the exact strings `set_conn_config/2` and `authorize/5` send to Postgres.
- **One decision per extension.** The probe row's `extension` differs, so a read is decided for
  each extension `get_read_authorizations/4` checks (`broadcast`, and `presence` when presence is
  enabled), and a write for the one extension asked. `SqlLogex.decide/3` takes about 11 µs for
  the user-channel policies (measured locally).
- **What it records.** All of this runs in a detached task, so it can't slow down or fail the real
  check.
  - Every decision emits `[:realtime, :tenants, :sql_logex, :shadow, :read | :write]` with an
    outcome: `:match`, `:mismatch`, `:fallback`, or `:no_real_answer` when the database check
    errored. Every mismatch is also logged as a warning.
  - The same metadata has a `reason` tag: for a `:fallback`, the category of why it fell back
    (`SqlLogex.Reason.category/1`, a small fixed set like `:role`, `:function_custom` or
    `:operator`), `:none` for the other outcomes. So the metrics show which kinds of constructs
    cost coverage.
  - `:unavailable` means no snapshot could be loaded. `:exception` means deciding raised.
  - `:timing` covers the whole shadow check, the cache lookup included.
  - `Realtime.PromEx.Plugins.SqlLogex` turns these into per-tenant metrics.

**Enforce mode** is not built. It would use the library's answer whenever it decided, and ask the
database only on a fallback:

- `:allow` and `:deny` fill the `Policies` struct. The simplest rule is to fall back for the whole
  call if any extension does.
- The snapshot has to be ready before a burst of reconnects arrives, and a join must never wait for
  a load. So it is loaded when the tenant's database connection starts (`Realtime.Tenants.Connect`),
  without delaying "ready", instead of on the first join.
- A fingerprint of everything the snapshot reads (policies, function definitions, settings) is
  polled every few minutes, and the snapshot reloads only when the fingerprint changes.
- The loader rules out what "Not done" lists, and the open decisions below need answers.

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
  - Postgres 14 and 15 give the same coverage, also with 0 mismatches (checked locally).
- Shadow mode in Realtime: loader, cache, env, the comparison and its metrics (see "In Realtime").

### Not done

- **Enforce mode.** See "In Realtime" for what it needs.
- **What shadow mode records.** It counts a database check that raised as "no real answer", not
  as a mismatch. A decided answer where Postgres raised should count as a mismatch, as it does in
  the differential test.
- **Role membership.** Policies match roles by inherited membership. The snapshot doesn't record
  memberships between `anon`, `authenticated` and `service_role`. So a tenant that runs
  `GRANT anon TO authenticated` gets a wrong answer for a policy `TO anon`. The loader has to check
  for that (`pg_has_role`) and fall back. Shadow mode doesn't need it: such a case shows up as a
  mismatch.
- **Other things the loader has to rule out before enforcing:**
  - database- or role-level defaults (`pg_db_role_setting`) for the settings the policies read or
    for `search_path`
  - revoked `EXECUTE` on the inlined functions, or revoked `USAGE` on `auth`/`realtime`
  - user triggers on `realtime.messages`
- **Policy changes.** Only the cache's expiry notices them, after up to 5 minutes.
- No CI job runs the library's own tests yet (only the Realtime suite runs the differential test).

### Planned, or maybe

- Enforce mode, with the snapshot loaded when the tenant's database connection starts and a
  fingerprint poll to notice changes (see "In Realtime").
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
  decide. Which answer wins has to be decided before enforcing.
- **Where enforce mode decides.** There are two options:
  - On the node holding the tenant's database connection, where shadow mode runs. That saves the
    query, but not the RPC.
  - On the node the client is connected to, before the RPC. That saves both, but needs a snapshot
    on every node with clients of that tenant.
