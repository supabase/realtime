defmodule Extensions.PostgresCdcRls.Replications do
  @moduledoc """
  SQL queries that use PostgresCdcRls.ReplicationPoller to create a temporary slot and poll the write-ahead log.
  """

  import Postgrex, only: [query: 3]

  @spec prepare_replication(pid(), String.t()) ::
          {:ok, Postgrex.Result.t()} | {:error, Postgrex.Error.t()}
  def prepare_replication(conn, slot_name) do
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
  end

  @spec terminate_backend(pid(), String.t()) ::
          {:ok, :terminated} | {:error, :slot_not_found | Postgrex.Error.t()}
  def terminate_backend(conn, slot_name) do
    slots =
      query(conn, "select active_pid from pg_replication_slots where slot_name = $1", [slot_name])

    case slots do
      {:ok, %Postgrex.Result{rows: [[backend]]}} ->
        case query(conn, "select pg_terminate_backend($1)", [backend]) do
          {:ok, _resp} -> {:ok, :terminated}
          {:error, erroer} -> {:error, erroer}
        end

      {:ok, %Postgrex.Result{num_rows: 0}} ->
        {:error, :slot_not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  @spec get_pg_stat_activity_diff(pid(), integer()) ::
          {:ok, integer()} | {:error, Postgrex.Error.t()}
  def get_pg_stat_activity_diff(conn, db_pid) do
    query =
      query(
        conn,
        "select
         extract(
          epoch from (now() - state_change)
         )::int as diff
         from pg_stat_activity where application_name = 'realtime_rls' and pid = $1",
        [db_pid]
      )

    case query do
      {:ok, %{rows: [[diff]]}} ->
        {:ok, diff}

      {:error, error} ->
        {:error, error}
    end
  end

  def list_changes(conn, slot_name, publication, max_changes, max_record_bytes) do
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
          coalesce(
            string_agg(
              realtime.quote_wal2json(format('%I.%I', schemaname, tablename)::regclass),
              ','
            ) filter (where ppt.tablename is not null),
            ''
          ) w2j_add_tables
        from
          pg_publication pp
          left join pg_publication_tables ppt
            on pp.pubname = ppt.pubname
        where
          pp.pubname = $1
        group by
          pp.pubname
        limit 1
      ),
      w2j as (
        select
          x.*, pub.w2j_add_tables
        from
          pub,
          pg_logical_slot_get_changes(
            $2, null, $3,
            'include-pk', 'true',
            'include-transaction', 'false',
            'include-timestamp', 'true',
            'include-type-oids', 'true',
            'format-version', '2',
            'actions', pub.w2j_actions,
            'add-tables', pub.w2j_add_tables
          ) x
      )
      select
        xyz.wal,
        xyz.is_rls_enabled,
        xyz.subscription_ids,
        xyz.errors
      from
        w2j,
        realtime.apply_rls(
          wal := w2j.data::jsonb,
          max_record_bytes := $4
        ) xyz(wal, is_rls_enabled, subscription_ids, errors)
      where
        w2j.w2j_add_tables <> ''
        and xyz.subscription_ids[1] is not null",
      [
        publication,
        slot_name,
        max_changes,
        max_record_bytes
      ]
    )
  end
end
