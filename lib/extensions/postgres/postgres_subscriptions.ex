defmodule Extensions.Postgres.Subscriptions do
  @moduledoc """
  This module consolidates subscriptions handling
  """
  require Logger
  import Postgrex, only: [transaction: 2, query: 3, rollback: 2]

  @type tid() :: :ets.tid()
  @type conn() :: DBConnection.conn()

  @spec create(conn(), String.t(), map()) :: {:ok, nil} | {:error, any()}
  def create(conn, publication, params) do
    transaction(conn, fn conn ->
      case fetch_publication_tables(conn, publication) do
        oids when oids != %{} ->
          case insert_topic_subscriptions(conn, params, oids) do
            {:ok, nil} ->
              nil

            {:error, error} ->
              Logger.error("Didn't create the subscription #{inspect(params.config)}")
              rollback(conn, error)
          end

        _ ->
          rollback(conn, "Entity oids do not exist")
      end
    end)
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

  @spec fetch_database_roles(conn()) :: []
  def fetch_database_roles(conn) do
    case query(conn, "select rolname from pg_authid", []) do
      {:ok, %{rows: rows}} ->
        rows |> List.flatten()

      _ ->
        []
    end
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

  @spec enrich_subscription_params(map(), [String.t()], map()) :: map()
  def enrich_subscription_params(params, _database_roles, oids) do
    %{claims: claims, topic: topic, id: id} = params

    # claims_role = (Enum.member?(database_roles, claims["role"]) && claims["role"]) || nil

    subs_params = %{
      id: id,
      claims: claims,
      # TODO: remove? claims_role: claims_role,
      entities: [],
      filters: [],
      topic: topic
    }

    # TODO: what if a table name consist ":" symbol?
    case String.split(topic, ":") do
      [schema, table, filters] ->
        String.split(filters, ~r/(\=|\.)/)
        |> case do
          [_, "eq", _] = filters ->
            %{subs_params | filters: [List.to_tuple(filters)], entities: Map.get(oids, {schema, table}, [])}

          _ ->
            %{subs_params | filters: filters}
        end

      [schema, table] ->
        case oids[{schema, table}] do
          nil -> raise("No #{schema} and #{table} in #{inspect(oids)}")
          entities -> %{subs_params | entities: entities}
        end

        %{subs_params | entities: Map.get(oids, {schema, table}, [])}

      [schema] ->
        case oids[{schema}] do
          nil -> raise("No #{schema} in #{inspect(oids)}")
          entities -> %{subs_params | entities: entities}
        end

      _ ->
        Logger.error("Unknown topic #{inspect(topic)}")
        subs_params
    end
  end

  @spec insert_topic_subscriptions(conn(), map(), map()) ::
          {:ok, nil} | {:error, any()}
  def insert_topic_subscriptions(conn, params, oids) do
    transform_to_oid_view(oids, params.config)
    |> case do
      nil ->
        {:error, "No match between subscription params and entity oids"}

      views ->
        bin_uuid = UUID.string_to_binary!(params.id)
        sql = "insert into realtime.subscription
              (subscription_id, entity, filters, claims)
              values ($1, $2, $3, $4)
              on conflict (subscription_id, entity, filters)
              do update set claims = excluded.claims, created_at = now()"

        transaction(conn, fn conn ->
          for view <- views do
            {entity, filters} =
              case view do
                {entity, filters} -> {entity, filters}
                entity -> {entity, []}
              end

            case query(conn, sql, [bin_uuid, entity, filters, params.claims]) do
              {:ok, _} -> nil
              {:error, error} -> rollback(conn, error)
            end
          end

          nil
        end)
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
