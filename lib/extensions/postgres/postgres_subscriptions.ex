defmodule Extensions.Postgres.Subscriptions do
  @moduledoc """
  This module consolidates subscriptions handling
  """
  require Logger
  import Postgrex, only: [transaction: 2, query: 3, query!: 3, rollback: 2]

  @type conn() :: Postgrex.conn()

  @spec create(conn(), String.t(), list(map())) ::
          {:ok, Postgrex.Result.t()} | {:error, Postgrex.Result.t() | Exception.t() | String.t()}
  def create(conn, publication, params_list) do
    sql = "with sub_tables as (
		    select
			    rr.entity
		    from
			    pg_publication_tables pub,
			    lateral (
				    select
					    format('%I.%I', pub.schemaname, pub.tablename)::regclass entity
			    ) rr
		    where
			    pub.pubname = $1
			  and pub.schemaname like (case $2 when '*' then '%' else $2 end)
			  and pub.tablename like (case $3 when '*' then '%' else $3 end)
	    )
	    insert into realtime.subscription as x(
		    subscription_id,
		    entity,
        filters,
        claims
      )
      select
        $4::text::uuid,
        sub_tables.entity,
        $6,
        $5
      from
        sub_tables
        on conflict
        (subscription_id, entity, filters)
        do update set
        claims = excluded.claims,
        created_at = now()
      returning
         id"

    transaction(conn, fn conn ->
      params_list
      |> Enum.map(fn %{id: id, claims: claims, params: params} ->
        with [schema, table, filters] <- parse_subscription_params(params),
             {:ok, result} <- query(conn, sql, [publication, schema, table, id, claims, filters]) do
          result
        else
          _ -> rollback(conn, :malformed_subscription_params)
        end
      end)
    end)
  end

  @spec delete(conn(), String.t()) :: any()
  def delete(conn, id) do
    Logger.debug("Delete subscription")
    sql = "delete from realtime.subscription where subscription_id = $1"
    # TODO: connection can be not available
    {:ok, _} = query(conn, sql, [id])
  end

  @spec delete_all(conn()) :: {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  def delete_all(conn) do
    Logger.debug("Delete all subscriptions")
    query(conn, "delete from realtime.subscription;", [])
  end

  @spec delete_multi(conn(), [Ecto.UUID.t()]) ::
          {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  def delete_multi(conn, ids) do
    Logger.debug("Delete multi ids subscriptions")
    sql = "delete from realtime.subscription where subscription_id = ANY($1::uuid[])"
    query(conn, sql, [ids])
  end

  @spec maybe_delete_all(conn()) :: {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  def maybe_delete_all(conn) do
    query(
      conn,
      "do $$
        begin
          if exists (
            select 1
            from pg_tables
            where schemaname = 'realtime'
              and tablename  = 'subscription'
          )
          then
            delete from realtime.subscription;
          end if;
      end $$",
      []
    )
  end

  @spec fetch_publication_tables(conn(), String.t()) ::
          %{
            {<<_::1>>} => [integer()],
            {String.t()} => [integer()],
            {String.t(), String.t()} => [integer()]
          }
          | %{}
  def fetch_publication_tables(conn, publication) do
    sql = "select
    schemaname, tablename, format('%I.%I', schemaname, tablename)::regclass as oid
    from pg_publication_tables where pubname = $1"

    case query(conn, sql, [publication]) do
      {:ok, %{columns: ["schemaname", "tablename", "oid"], rows: rows}} ->
        Enum.reduce(rows, %{}, fn [schema, table, oid], acc ->
          Map.put(acc, {schema, table}, [oid])
          |> Map.update({schema}, [oid], &[oid | &1])
          |> Map.update({"*"}, [oid], &[oid | &1])
        end)
        |> Enum.reduce(%{}, fn {k, v}, acc -> Map.put(acc, k, Enum.sort(v)) end)

      _ ->
        %{}
    end
  end

  defp parse_subscription_params(params) do
    case params do
      %{"schema" => schema, "table" => table, "filter" => filter} ->
        with [col, rest] <- String.split(filter, "=", parts: 2),
             [filter_type, value] <- String.split(rest, ".", parts: 2) do
          [schema, table, [{col, filter_type, value}]]
        else
          _ -> []
        end

      %{"schema" => schema, "table" => table} ->
        [schema, table, []]

      %{"schema" => schema} ->
        [schema, "*", []]

      _ ->
        []
    end
  end
end
