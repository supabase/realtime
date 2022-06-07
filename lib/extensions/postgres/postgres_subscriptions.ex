defmodule Extensions.Postgres.Subscriptions do
  @moduledoc """
  This module consolidates subscriptions handling
  """
  require Logger
  import Postgrex, only: [query: 3]

  @type conn() :: DBConnection.conn()

  @spec create(conn(), String.t(), map()) :: :ok
  def create(conn, publication, params) do
    case fetch_publication_tables(conn, publication) do
      oids when oids != %{} ->
        if !insert_topic_subscriptions(conn, params, oids) do
          Logger.error("Didn't create the subscription #{inspect(params.config)}")
        end

      other ->
        Logger.error("Unacceptable oids #{inspect(other)}")
    end
  end

  @spec delete(conn(), String.t()) :: any()
  def delete(conn, id) do
    Logger.debug("Delete subscription")
    sql = "delete from realtime.subscription where subscription_id = $1"
    # TODO: connection can be not available
    {:ok, _} = query(conn, sql, [id])
  end

  def delete_all(conn) do
    Logger.debug("Delete all subscriptions")
    query(conn, "delete from realtime.subscription;", [])
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
          [filter_field, "eq", filter_value] ->
            %{
              subs_params
              | filters: [{filter_field, "eq", filter_value}],
                entities: oids[{schema, table}]
            }

          _ ->
            %{subs_params | filters: filters}
        end

      [schema, table] ->
        case oids[{schema, table}] do
          nil -> raise("No #{schema} and #{table} in #{inspect(oids)}")
          entities -> %{subs_params | entities: entities}
        end

        %{subs_params | entities: oids[{schema, table}]}

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

  @spec insert_topic_subscriptions(conn(), map(), map()) :: boolean()
  def insert_topic_subscriptions(conn, params, oids) do
    transform_to_oid_view(oids, params.config)
    |> case do
      nil ->
        false

      views ->
        bin_uuid = UUID.string_to_binary!(params.id)
        sql = "insert into realtime.subscription
              (subscription_id, entity, filters, claims)
              values ($1, $2, $3, $4)
              on conflict (subscription_id, entity, filters)
              do update set claims = excluded.claims, created_at = now()"

        Enum.reduce(views, true, fn view, acc ->
          {entity, filters} =
            case view do
              {entity, filters} -> {entity, filters}
              entity -> {entity, []}
            end

          query(conn, sql, [bin_uuid, entity, filters, params.claims])
          |> case do
            {:error, reason} ->
              Logger.error("Insert subscriptions query #{inspect(reason)}")
              false

            _ ->
              acc
          end
        end)
    end
  end

  @spec transform_to_oid_view(map(), map()) :: [pos_integer()] | [{pos_integer(), list()}] | nil
  def transform_to_oid_view(oids, config) do
    case config do
      %{"schema" => schema, "table" => table, "filter" => filter} ->
        [column, rule] = String.split(filter, "=")
        [op, value] = String.split(rule, ".")
        [oid] = oids[{schema, table}]
        [{oid, [{column, op, value}]}]

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
