defmodule Realtime.Tenants.Migrations.ListChangesFromPartitionLeaves do
  @moduledoc false

  use Ecto.Migration

  # wal2json reports a change to a partitioned table under the leaf partition holding the row. With
  # publish_via_partition_root, pg_publication_tables lists only the partitioned table, so its leaves
  # were left out of add-tables and their changes were dropped. Watch the leaves and report each
  # change as the table it is published as, which is what pgoutput does with that option.
  def change do
    execute(~S"""
    CREATE OR REPLACE FUNCTION realtime.list_changes(publication name, slot_name name, max_changes int, max_record_bytes int)
    RETURNS TABLE(
      wal jsonb,
      is_rls_enabled boolean,
      subscription_ids uuid[],
      errors text[],
      slot_changes_count bigint
    )
    LANGUAGE sql
    SET log_min_messages TO 'fatal'
    AS $$
      -- Each published table with the leaf partitions wal2json reports its changes under. A table
      -- that isn't partitioned is its own leaf.
      WITH pub_tables AS (
        SELECT
          ppt.schemaname,
          ppt.tablename,
          coalesce(pt.relid, format('%I.%I', ppt.schemaname, ppt.tablename)::regclass) AS leaf
        FROM pg_publication_tables ppt
        LEFT JOIN LATERAL pg_partition_tree(format('%I.%I', ppt.schemaname, ppt.tablename)::regclass) pt
          ON pt.isleaf
        WHERE ppt.pubname = publication
      ),
      pub AS (
        SELECT
          concat_ws(
            ',',
            CASE WHEN bool_or(pubinsert) THEN 'insert' ELSE NULL END,
            CASE WHEN bool_or(pubupdate) THEN 'update' ELSE NULL END,
            CASE WHEN bool_or(pubdelete) THEN 'delete' ELSE NULL END
          ) AS w2j_actions,
          coalesce(
            string_agg(
              realtime.quote_wal2json(pubt.leaf),
              ','
            ) filter (WHERE pubt.leaf IS NOT NULL),
            ''
          ) AS w2j_add_tables
        FROM pg_publication pp
        LEFT JOIN pub_tables pubt ON true
        WHERE pp.pubname = publication
        GROUP BY pp.pubname
        LIMIT 1
      ),
      -- MATERIALIZED ensures pg_logical_slot_get_changes is called exactly once
      w2j AS MATERIALIZED (
        SELECT x.*, pub.w2j_add_tables
        FROM pub,
             pg_logical_slot_get_changes(
               slot_name, null, max_changes,
               'include-pk', 'true',
               'include-transaction', 'false',
               'include-timestamp', 'true',
               'include-type-oids', 'true',
               'format-version', '2',
               'actions', pub.w2j_actions,
               'add-tables', pub.w2j_add_tables
             ) x
      ),
      slot_count AS (
        SELECT count(*)::bigint AS cnt
        FROM w2j
        WHERE w2j.w2j_add_tables <> ''
      ),
      rls_filtered AS (
        SELECT xyz.wal, xyz.is_rls_enabled, xyz.subscription_ids, xyz.errors
        FROM w2j,
             LATERAL (SELECT w2j.data::jsonb AS wal) change,
             realtime.apply_rls(
               -- Report a leaf partition's change as the table it is published as
               wal := change.wal || coalesce(
                 (
                   SELECT jsonb_build_object('schema', pubt.schemaname, 'table', pubt.tablename)
                   FROM pub_tables pubt
                   WHERE pubt.leaf = to_regclass(quote_ident(change.wal ->> 'schema') || '.' || quote_ident(change.wal ->> 'table'))
                   LIMIT 1
                 ),
                 '{}'
               ),
               max_record_bytes := max_record_bytes
             ) xyz(wal, is_rls_enabled, subscription_ids, errors)
        WHERE w2j.w2j_add_tables <> ''
          AND xyz.subscription_ids[1] IS NOT NULL
      )
      SELECT rf.wal, rf.is_rls_enabled, rf.subscription_ids, rf.errors, sc.cnt
      FROM rls_filtered rf, slot_count sc

      UNION ALL

      SELECT null, null, null, null, sc.cnt
      FROM slot_count sc
      WHERE NOT EXISTS (SELECT 1 FROM rls_filtered)
    $$;
    """)

    execute(~S"""
    CREATE OR REPLACE FUNCTION realtime.list_changes_sync(publication name, slot_name name, max_changes int, max_record_bytes int)
    RETURNS TABLE(
      wal jsonb,
      is_rls_enabled boolean,
      subscription_ids uuid[],
      errors text[],
      slot_changes_count bigint
    )
    LANGUAGE sql
    SET log_min_messages TO 'fatal'
    AS $$
      -- Each published table with the leaf partitions wal2json reports its changes under. A table
      -- that isn't partitioned is its own leaf.
      WITH pub_tables AS (
        SELECT
          ppt.schemaname,
          ppt.tablename,
          coalesce(pt.relid, format('%I.%I', ppt.schemaname, ppt.tablename)::regclass) AS leaf
        FROM pg_publication_tables ppt
        LEFT JOIN LATERAL pg_partition_tree(format('%I.%I', ppt.schemaname, ppt.tablename)::regclass) pt
          ON pt.isleaf
        WHERE ppt.pubname = publication
      ),
      pub AS (
        SELECT
          concat_ws(
            ',',
            CASE WHEN bool_or(pubinsert) THEN 'insert' ELSE NULL END,
            CASE WHEN bool_or(pubupdate) THEN 'update' ELSE NULL END,
            CASE WHEN bool_or(pubdelete) THEN 'delete' ELSE NULL END
          ) AS w2j_actions,
          coalesce(
            string_agg(
              realtime.quote_wal2json(pubt.leaf),
              ','
            ) filter (WHERE pubt.leaf IS NOT NULL),
            ''
          ) AS w2j_add_tables
        FROM pg_publication pp
        LEFT JOIN pub_tables pubt ON true
        WHERE pp.pubname = publication
        GROUP BY pp.pubname
        LIMIT 1
      ),
      -- MATERIALIZED ensures the slot is read exactly once.
      consumed AS MATERIALIZED (
        SELECT x.*, pub.w2j_add_tables
        FROM pub,
             realtime.settled_changes(
               slot_name, max_changes,
               'include-pk', 'true',
               'include-transaction', 'false',
               'include-timestamp', 'true',
               'include-type-oids', 'true',
               'format-version', '2',
               'actions', pub.w2j_actions,
               'add-tables', pub.w2j_add_tables
             ) x
      ),
      slot_count AS (
        SELECT count(*)::bigint AS cnt
        FROM consumed
        WHERE consumed.w2j_add_tables <> ''
      ),
      rls_filtered AS (
        SELECT xyz.wal, xyz.is_rls_enabled, xyz.subscription_ids, xyz.errors
        FROM consumed,
             LATERAL (SELECT consumed.data::jsonb AS wal) change,
             realtime.apply_rls(
               -- Report a leaf partition's change as the table it is published as
               wal := change.wal || coalesce(
                 (
                   SELECT jsonb_build_object('schema', pubt.schemaname, 'table', pubt.tablename)
                   FROM pub_tables pubt
                   WHERE pubt.leaf = to_regclass(quote_ident(change.wal ->> 'schema') || '.' || quote_ident(change.wal ->> 'table'))
                   LIMIT 1
                 ),
                 '{}'
               ),
               max_record_bytes := max_record_bytes
             ) xyz(wal, is_rls_enabled, subscription_ids, errors)
        WHERE consumed.w2j_add_tables <> ''
          AND xyz.subscription_ids[1] IS NOT NULL
      )
      SELECT rf.wal, rf.is_rls_enabled, rf.subscription_ids, rf.errors, sc.cnt
      FROM rls_filtered rf, slot_count sc

      UNION ALL

      SELECT null, null, null, null, sc.cnt
      FROM slot_count sc
      WHERE NOT EXISTS (SELECT 1 FROM rls_filtered)
    $$;
    """)
  end
end
