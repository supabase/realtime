# WALRUS regression suite

`pg_regress` tests inherited from [supabase/walrus](https://github.com/supabase/walrus).

They cover the SQL side of Postgres Changes end to end: a real logical replication slot, `wal2json` output, `realtime.apply_rls`, `realtime.subscription_check_filters`, `realtime.is_visible_through_filters`, RLS, column permissions, `selected_columns`, `action_filter` and the filter operators.

## What they run against

`priv/repo/tenant_db_dump_<major>.sql` which is the same dump `Realtime.Tenants.Migrations` loads into a fresh tenant. Nothing here builds the schema independently, so a change to the tenant migrations that breaks Postgres Changes shows up as a diff in `expected/`.

`setup.sql` adds the two things the `supabase/postgres` image doesn't already provide: a `for all tables` publication, and the `auth.uid()` a real project has (the image ships an older one that can't see the claims `apply_rls` sets. See the comment in that file).
`fixtures.sql` defines the `walrus` / `polling_query` views and the `norm()`, `clear_wal()`, `seed_uuid()` helpers the tests are written against.

## Running

```bash
mise run walrus                     # whole suite (Postgres 17 by default)
mise run walrus test_simple_insert  # one or more tests

POSTGRES_IMAGE=supabase/postgres:15.14.1.167 mise run walrus
POSTGRES_IMAGE=supabase/postgres:17.9.0.019-orioledb mise run walrus
```

`mise run walrus` is a thin wrapper over `test/walrus/run.sh`; either works.

Every run drops what actually happened in `results/` (gitignored). On a failure the diff is printed, and once you've read it and agree the new output is correct:

```bash
cp test/walrus/results/<test>.out test/walrus/expected/<test>.out
```

## Layout

| Path          | Purpose                                                            |
| ------------- | ------------------------------------------------------------------ |
| `sql/`        | one file per test, run in alphabetical order in a shared database  |
| `expected/`   | the psql transcript each test must reproduce, byte for byte        |
| `setup.sql`   | the publication and `auth.uid()` the image doesn't provide          |
| `fixtures.sql`| helper views and functions the tests call                          |
| `run.sh`      | boots the database, loads the dump, drives `pg_regress`            |
| `results/`    | last run's actual output, gitignored                               |

Each test is responsible for its own cleanup (`drop table`, `pg_drop_replication_slot`, `truncate realtime.subscription`) because they all share one database.
