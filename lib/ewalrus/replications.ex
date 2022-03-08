defmodule Ewalrus.Replications do
  require Logger
  import Postgrex, only: [transaction: 2, query: 3]

  def prepare_replication(conn, slot_name) do
    {:ok, res} =
      transaction(conn, fn conn ->
        query(
          conn,
          "select
            case when not exists (
              select 1
              from pg_replication_slots
              where slot_name = $1
            )
            then (
              select 1 from pg_create_logical_replication_slot($1, 'wal2json', 'true')
            )
            else 1
            end;",
          [slot_name]
        )

        query(conn, "set search_path = ''", [])
      end)
  end

  def list_changes(conn, slot_name, publication, max_record_bytes) do
    query(
      conn,
      "with pub as (
        select
          concat_ws(
            ',',
            case when bool_or(pubinsert) then 'insert' else null end,
            case when bool_or(pubupdate) then 'update' else null end,
            case when bool_or(pubdelete) then 'delete' else null end
          ) as w2j_actions,
          string_agg(realtime.quote_wal2json(format('%I.%I', schemaname, tablename)::regclass), ',') w2j_add_tables
        from
          pg_publication pp
          join pg_publication_tables ppt
            on pp.pubname = ppt.pubname
        where
          pp.pubname = $1
        group by
          pp.pubname
        limit 1
      )
      select
        xyz.wal,
        xyz.is_rls_enabled,
        xyz.subscription_ids,
        xyz.errors
      from
        pub,
        lateral (
          select
            *
          from
            pg_logical_slot_get_changes(
              $2, null, null,
              'include-pk', '1',
              'include-transaction', 'false',
              'include-timestamp', 'true',
              'write-in-chunks', 'true',
              'format-version', '2',
              'actions', coalesce(pub.w2j_actions, ''),
              'add-tables', pub.w2j_add_tables
            )
        ) w2j,
        lateral (
          select
            x.wal,
            x.is_rls_enabled,
            x.subscription_ids,
            x.errors
          from
            realtime.apply_rls(
              wal := w2j.data::jsonb,
              max_record_bytes := $3
            ) x(wal, is_rls_enabled, subscription_ids, errors)
        ) xyz
      where coalesce(pub.w2j_add_tables, '') <> ''
        and xyz.subscription_ids[1] is not null",
      [
        publication,
        slot_name,
        max_record_bytes
      ]
    )
  end
end
