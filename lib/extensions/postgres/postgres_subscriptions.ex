defmodule Extensions.Postgres.Subscriptions do
  @moduledoc """
  This module consolidates subscriptions handling
  """
  require Logger
  import Postgrex, only: [transaction: 2, query: 3]

  @type tid() :: :ets.tid()
  @type conn() :: DBConnection.conn()

  @spec create(conn(), String.t(), map()) :: {:ok, Postgrex.Result.t()} | {:error, Postgrex.Result.t() | Exception.t() | String.t()}
  def create(conn, publication, %{id: id, config: config, claims: claims}) do
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

    with [schema, table, filters] <-
           (case config do
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
            end),
         {:ok,
          %Postgrex.Result{
            num_rows: num_rows
          } = result}
         when num_rows > 0 <- query(conn, sql, [publication, schema, table, id, claims, filters]) do
      {:ok, result}
    else
      {_, other} ->
        {:error, other}

      [] ->
        {:error, "malformed postgres config"}
    end
  end

  @spec update_all(conn(), tid(), String.t()) :: {:ok, nil} | {:error, any()}
  def update_all(conn, tid, publication) do
    transaction(conn, fn conn ->
      delete_all(conn)

      fn {_pid, id, config, claims, _}, _ ->
        subscription_opts = %{
          id: id,
          config: config,
          claims: claims
        }

        create(conn, publication, subscription_opts)
      end
      |> :ets.foldl(nil, tid)

      nil
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

  @spec delete_multi(conn(), [Ecto.UUID.t()]) :: any()
  def delete_multi(conn, ids) do
    Logger.debug("Delete multi ids subscriptions")
    sql = "delete from realtime.subscription where subscription_id = ANY($1::uuid[])"
    # TODO: connection can be not available
    {:ok, _} = query(conn, sql, [ids])
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

  def sync_subscriptions() do
    :ok
  end

  #################

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

  @spec transform_to_oid_view(map(), map()) :: [pos_integer()] | [{pos_integer(), list()}] | nil
  def transform_to_oid_view(oids, config) do
    case config do
      %{"schema" => schema, "table" => table, "filter" => filter} ->
        with [oid] when is_integer(oid) <- oids[{schema, table}],
             [column, rule] <- String.split(filter, "="),
             [op, value] <- String.split(rule, ".") do
          [{oid, [{column, op, value}]}]
        else
          _ -> nil
        end

      %{"schema" => schema, "table" => "*"} ->
        oids[{schema}]

      %{"schema" => schema, "table" => table} ->
        oids[{schema, table}]

      %{"schema" => schema} ->
        oids[{schema}]
    end
  end

  # transform %{"id" => %{"lt" => 10, "gt" => 2}}
  # to [{"id", "gt", 2}, {"id", "lt", 10}]
  def flat_filters(filters) do
    Map.to_list(filters)
    |> Enum.reduce([], fn {column, filter}, acc ->
      acc ++
        for {operation, value} <- Map.to_list(filter) do
          {column, operation, value}
        end
    end)
  end
end
