defmodule Realtime.Tenants.Migrations.AddListChangesSettled do
  @moduledoc false

  use Ecto.Migration

  def change do
    execute(~S"""
    -- A drop-in replacement for pg_logical_slot_get_changes, taking and forwarding the same
    -- plugin options, that holds back a change whose transaction has not settled yet. It works
    -- the boundary out for itself, so it takes no upto_lsn.
    CREATE OR REPLACE FUNCTION realtime.settled_changes(
      slot_name name, max_changes int, VARIADIC opts text[])
    RETURNS TABLE(lsn pg_lsn, xid xid, data text)
    LANGUAGE plpgsql
    VOLATILE
    AS $$
    declare
      peek_opts text[] := opts;
      xids text[];
      commit_lsns pg_lsn[];
      boundary pg_lsn;
      snapshot pg_snapshot;
      i int;
    begin
      -- Each statement in a volatile function takes its own snapshot, which is what lets the
      -- check below see a writer that was still in flight when the peek ran. Under REPEATABLE
      -- READ the snapshot never advances, so a deferred change would never be released.
      if current_setting('transaction_isolation') <> 'read committed' then
        raise exception 'realtime.settled_changes requires READ COMMITTED';
      end if;

      -- Commit markers carry the transaction end lsn, the only position the read below can stop
      -- at without cutting a transaction in half. The caller does not want them in the output,
      -- so they are forced on for the peek alone.
      for i in 1..array_length(peek_opts, 1) by 2 loop
        if peek_opts[i] = 'include-transaction' then peek_opts[i + 1] := 'true'; end if;
      end loop;

      -- One row per transaction, in commit order, rather than per change: the whole batch would
      -- otherwise be carried back through the pooler a second time just to locate the cut.
      select array_agg(t.xid::text order by t.commit_lsn), array_agg(t.commit_lsn order by t.commit_lsn)
        into xids, commit_lsns
        from (
          select p.xid, max(p.lsn) filter (where p.data::jsonb->>'action' = 'C') as commit_lsn
          from pg_logical_slot_peek_changes(slot_name, null, max_changes, variadic peek_opts) p
          group by p.xid
        ) t
        where t.commit_lsn is not null;

      if xids is null then
        return;
      end if;

      -- Taken after the peek is materialized, so a writer that was still in flight during
      -- decoding is guaranteed to show up here.
      snapshot := pg_current_snapshot();

      -- A commit record reaches the WAL before the writer leaves the proc array, so a change can
      -- be decoded while its row is invisible. apply_rls would resolve a policy against a row it
      -- cannot see and authorize it for nobody, while the read consumed it regardless.
      --
      -- xip lists transactions running when the snapshot was taken. It does not cover a writer
      -- whose xid sits at or beyond xmax, which never appears there, so the horizon is checked
      -- too. age() counts backwards from the current xid and so compares correctly across
      -- wraparound.
      --
      -- Stopping at the first unsettled transaction rather than discarding the whole batch:
      -- bailing entirely starves the poller wherever writes overlap polls, which on a cluster
      -- that commits behind a standby is most of the time.
      for i in 1..array_length(xids, 1) loop
        if exists (
             select 1 from pg_snapshot_xip(snapshot) running(x)
             where running.x::xid::text = xids[i]
           )
           or age(xids[i]::xid) <= age(pg_snapshot_xmax(snapshot)::xid) then
          exit;
        end if;

        boundary := commit_lsns[i];
      end loop;

      if boundary is null then
        return;
      end if;

      -- A fixed boundary keeps a transaction that committed since the peek out of this batch,
      -- where it would not have been checked.
      return query
        select p.* from pg_logical_slot_get_changes(slot_name, boundary, null, variadic opts) p;
    end;
    $$;
    """)

    execute(~S"""
    CREATE FUNCTION realtime.list_changes_settled(publication name, slot_name name, max_changes int, max_record_bytes int)
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
      WITH pub AS (
        SELECT
          concat_ws(
            ',',
            CASE WHEN bool_or(pubinsert) THEN 'insert' ELSE NULL END,
            CASE WHEN bool_or(pubupdate) THEN 'update' ELSE NULL END,
            CASE WHEN bool_or(pubdelete) THEN 'delete' ELSE NULL END
          ) AS w2j_actions,
          coalesce(
            string_agg(
              realtime.quote_wal2json(format('%I.%I', schemaname, tablename)::regclass),
              ','
            ) filter (WHERE ppt.tablename IS NOT NULL),
            ''
          ) AS w2j_add_tables
        FROM pg_publication pp
        LEFT JOIN pg_publication_tables ppt ON pp.pubname = ppt.pubname
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
             realtime.apply_rls(
               wal := consumed.data::jsonb,
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

    execute("ALTER FUNCTION realtime.settled_changes(name, integer, text[]) OWNER TO supabase_realtime_admin")

    execute(
      "ALTER FUNCTION realtime.list_changes_settled(name, name, integer, integer) OWNER TO supabase_realtime_admin"
    )
  end
end
