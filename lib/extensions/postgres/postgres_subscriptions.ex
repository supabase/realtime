defmodule Extensions.Postgres.Subscriptions do
  require Logger
  import Postgrex, only: [query: 3]

  @type conn() :: DBConnection.conn()

  @spec create(conn(), String.t(), map()) :: :ok
  def create(conn, publication, params) do
    database_roles = fetch_database_roles(conn)
    oids = fetch_publication_tables(conn, publication)
    new_params = enrich_subscription_params(params, database_roles, oids)
    insert_topic_subscriptions(conn, new_params)
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
    query(conn, "truncate table realtime.subscription;", [])
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

  @spec insert_topic_subscriptions(conn(), map()) :: :ok
  def insert_topic_subscriptions(conn, params) do
    sql = "insert into realtime.subscription
             (subscription_id, entity, filters, claims)
           values ($1, $2, $3, $4)"
    bin_uuid = UUID.string_to_binary!(params.id)

    Enum.each(params.entities, fn entity ->
      query(conn, sql, [bin_uuid, entity, params.filters, params.claims])
    end)
  end
end
