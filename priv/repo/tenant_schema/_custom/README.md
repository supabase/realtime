# `_custom/` — SQL that pg-delta does not manage

Files in this folder are **preserved across `pgdelta schema export` runs**:
the exporter never writes here, never deletes anything here, and never counts
these files as "unmanaged".

Put here the SQL that pg-delta detects but does not model (reported as
`unmodeled_kind`): casts, operators, operator classes/families, text search
objects, statistics objects, transforms — plus idempotent DML your schema
depends on (write seeds as `INSERT … ON CONFLICT DO NOTHING`).

## What these files do — and do not do

- They ARE loaded into the shadow database by `pgdelta schema apply`, so
  modeled objects that depend on them (e.g. an index over a custom operator
  class) elaborate correctly, and re-exports keep working.
- They are NOT executed against your target database. You must deliver the
  same change through your normal migration channel.

## Link each file to its migration

Record the migration(s) that delivered a file as head-of-file comments:

    -- pgdelta-migration: ../../supabase/migrations/20260811120000_add_cast.sql

Use `-- pgdelta-migration: none` if a file deliberately has no migration twin.
`pgdelta schema lint` warns on missing or dangling references.

## Do not put modeled DDL here

Tables, views, functions, policies, … belong in the managed tree — the
exporter regenerates them. A modeled object kept here becomes a duplicate on
the next export and breaks `schema apply`. `pgdelta schema lint` warns when it
sees one.
