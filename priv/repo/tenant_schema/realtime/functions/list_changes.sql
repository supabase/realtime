create or replace function realtime.list_changes (
  publication      name,
  slot_name        name,
  max_changes      integer,
  max_record_bytes integer
)
  returns table (
    wal                jsonb,
    is_rls_enabled     boolean,
    subscription_ids   uuid[],
    errors             text[],
    slot_changes_count bigint
  )
  language sql
  set log_min_messages to 'fatal'
  AS $function$
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
$function$;

alter function "realtime"."list_changes"(name, name, integer, integer) owner to "supabase_realtime_admin";
