defmodule Realtime.Tenants.Migrations.CreateRealtimeBuildPreparedStatementSqlFunction do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute("""
    DO $$
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'wal_column') THEN
            CREATE TYPE realtime.wal_column AS (
              name text,
              type text,
              value jsonb,
              is_pkey boolean,
              is_selectable boolean
            );
        END IF;
    END$$;
    """)

    execute("create function realtime.build_prepared_statement_sql(
      prepared_statement_name text,
      entity regclass,
      columns realtime.wal_column[]
    )
      returns text
      language sql
    as $$
    /*
    Builds a sql string that, if executed, creates a prepared statement to
    tests retrive a row from *entity* by its primary key columns.

    Example
      select realtime.build_prepared_statment_sql('public.notes', '{\"id\"}'::text[], '{\"bigint\"}'::text[])
    */
      select
    'prepare ' || prepared_statement_name || ' as
      select
        exists(
          select
            1
          from
            ' || entity || '
          where
            ' || string_agg(quote_ident(pkc.name) || '=' || quote_nullable(pkc.value) , ' and ') || '
        )'
      from
        unnest(columns) pkc
      where
        pkc.is_pkey
      group by
        entity
    $$;")
  end
end
