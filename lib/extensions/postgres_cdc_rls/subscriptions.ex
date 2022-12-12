defmodule Extensions.PostgresCdcRls.Subscriptions do
  @moduledoc """
  This module consolidates subscriptions handling
  """
  require Logger
  import Postgrex, only: [transaction: 2, query: 3, rollback: 2]

  @type conn() :: Postgrex.conn()

  @filter_types ["eq", "neq", "lt", "lte", "gt", "gte"]

  @spec create(conn(), String.t(), list(map())) ::
          {:ok, Postgrex.Result.t()}
          | {:error,
             Exception.t() | :malformed_subscription_params | {:subscription_insert_failed, map()}}
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
        case parse_subscription_params(params) do
          {:ok, [schema, table, filters]} ->
            case query(conn, sql, [publication, schema, table, id, claims, filters]) do
              {:ok, %{num_rows: num} = result} when num > 0 ->
                result

              _ ->
                rollback(conn, {:subscription_insert_failed, params})
            end

          {:error, reason} ->
            rollback(conn, reason)
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

  @doc """
  Parses subscription filter parameters into something we can pass into our `create_subscription` query.

  We currently support the following filters: 'eq', 'neq', 'lt', 'lte', 'gt', 'gte`

  ## Examples

      iex> params = %{"schema" => "public", "table" => "messages", "filter" => "subject=eq.hey"}
      iex> Extensions.PostgresCdcRls.Subscriptions.parse_subscription_params(params)
      {:ok, ["public", "messages", [{"subject", "eq", "hey"}]]}

  An unsupported filter will respond with an error tuple:

      iex> params = %{"schema" => "public", "table" => "messages", "filter" => "subject=in.hey"}
      iex> Extensions.PostgresCdcRls.Subscriptions.parse_subscription_params(params)
      {:error, ~s(Error parsing `filter` params: ["in", "hey"])}

  Catch `undefined` filters:

      iex> params = %{"schema" => "public", "table" => "messages", "filter" => "undefined"}
      iex> Extensions.PostgresCdcRls.Subscriptions.parse_subscription_params(params)
      {:error, ~s(Error parsing `filter` params: ["undefined"])}

  """

  @spec parse_subscription_params(map()) :: {:ok, list} | {:error, binary()}
  def parse_subscription_params(params) do
    case params do
      %{"schema" => schema, "table" => table, "filter" => filter} ->
        with [col, rest] <- String.split(filter, "=", parts: 2),
             [filter_type, value] when filter_type in @filter_types <-
               String.split(rest, ".", parts: 2) do
          {:ok, [schema, table, [{col, filter_type, value}]]}
        else
          e -> {:error, "Error parsing `filter` params: #{inspect(e)}"}
        end

      %{"schema" => schema, "table" => table} ->
        {:ok, [schema, table, []]}

      %{"schema" => schema} ->
        {:ok, [schema, "*", []]}

      %{"table" => table} ->
        {:ok, ["public", table, []]}

      _ ->
        {:error,
         "No subscription params provided. Please provide at least a `schema` or `table` to subscribe to."}
    end
  end
end
