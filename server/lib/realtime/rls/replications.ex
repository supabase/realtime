defmodule Realtime.RLS.Replications do
  import Realtime.RLS.Repo

  alias Ecto.Multi

  def prepare_replication(slot_name, temporary_slot) do
    Multi.new()
    |> Multi.run(:create_slot, fn _, _ ->
      query(
        "select
          case when not exists (
            select 1
            from pg_replication_slots
            where slot_name = $1
          )
          then (
            select 1 from pg_create_logical_replication_slot($1, 'wal2json', $2)
          )
          else 1
          end;",
        [slot_name, temporary_slot]
      )
      |> case do
        {:ok, %Postgrex.Result{rows: [[1]]}} ->
          {:ok, slot_name}

        {_, error} ->
          {:error, error}
      end
    end)
    |> Multi.run(:search_path, fn _, _ ->
      # Enable schema-qualified table names for public schema
      # when casting prrelid to regclass in poll query
      case query("set search_path = ''", []) do
        {:ok, %Postgrex.Result{command: command}} -> {:ok, command}
        {_, error} -> {:error, error}
      end
    end)
    |> transaction()
    |> case do
      {:ok, multi_map} -> {:ok, multi_map}
      {:error, error} -> {:error, error}
      {:error, _, error, _} -> {:error, error}
    end
  end

  def list_changes(slot_name, publication, max_record_bytes) do
    query(
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
        xyz.users,
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
            x.users,
            x.errors
          from
            realtime.apply_rls(
              wal := w2j.data::jsonb,
              max_record_bytes := $3
            ) x(wal, is_rls_enabled, users, errors)
        ) xyz
      where coalesce(pub.w2j_add_tables, '') <> '' ",
      [
        publication,
        slot_name,
        max_record_bytes
      ]
    )
  end
end
