create or replace function realtime.settled_changes (
  slot_name   name,
  max_changes integer,
  VARIADIC    opts text[]
)
  returns table (
    lsn  pg_lsn,
    xid  xid,
    data text
  )
  language plpgsql
  AS $function$
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
$function$;

alter function "realtime"."settled_changes"(name, integer, text[]) owner to "supabase_realtime_admin";
