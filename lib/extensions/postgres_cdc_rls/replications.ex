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
      "select * from realtime.list_changes($1, $2, $3, $4)",
      [
        publication,
        slot_name,
        max_changes,
        max_record_bytes
      ]
    )
  end
end
