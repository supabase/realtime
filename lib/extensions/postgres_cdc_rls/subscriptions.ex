defmodule Extensions.PostgresCdcRls.Subscriptions do
  @moduledoc """
  This module consolidates subscriptions handling
  """
  use Realtime.Logs

  import Postgrex, only: [transaction: 2, query: 3, rollback: 2]

  @type conn() :: Postgrex.conn()
  @type filter :: {binary, binary, binary}
  @type subscription_params :: {action_filter :: binary, schema :: binary, table :: binary, [filter]}
  @type subscription_list :: [%{id: binary, claims: map, subscription_params: subscription_params}]

  @filter_types ["eq", "neq", "lt", "lte", "gt", "gte", "in"]

  @spec create(conn(), String.t(), subscription_list, pid(), pid()) ::
          {:ok, Postgrex.Result.t()}
          | {:error, Exception.t() | {:exit, term} | {:subscription_insert_failed, String.t()}}

  def create(conn, publication, subscription_list, manager, caller) do
    transaction(conn, fn conn ->
      Enum.map(subscription_list, fn %{id: id, claims: claims, subscription_params: params} ->
        case query(conn, publication, id, claims, params) do
          {:ok, %{num_rows: num} = result} when num > 0 ->
            send(manager, {:subscribed, {caller, id}})
            result

          {:ok, _} ->
            msg =
              "Unable to subscribe to changes with given parameters. Please check Realtime is enabled for the given connect parameters: [#{params_to_log(params)}]"

            rollback(conn, {:subscription_insert_failed, msg})

          {:error, exception} ->
            msg =
              "Unable to subscribe to changes with given parameters. An exception happened so please check your connect parameters: [#{params_to_log(params)}]. Exception: #{Exception.message(exception)}"

            rollback(conn, {:subscription_insert_failed, msg})
        end
      end)
    end)
  rescue
    e in DBConnection.ConnectionError -> {:error, e}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp query(conn, publication, id, claims, subscription_params) do
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
        claims,
        action_filter
      )
      select
        $4::text::uuid,
        sub_tables.entity,
        $6,
        $5,
        $7
      from
        sub_tables
        on conflict
        (subscription_id, entity, filters, action_filter)
        do update set
        claims = excluded.claims,
        created_at = now()
      returning
         id"
    {action_filter, schema, table, filters} = subscription_params
    query(conn, sql, [publication, schema, table, id, claims, filters, action_filter])
  end

  defp params_to_log({action_filter, schema, table, filters}) do
    [event: action_filter, schema: schema, table: table, filters: filters]
    |> Enum.map_join(", ", fn {k, v} -> "#{k}: #{to_log(v)}" end)
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
          if String.contains?(table, " ") do
            log_error(
              "TableHasSpacesInName",
              "Table name cannot have spaces: \"#{schema}\".\"#{table}\""
            )
          end

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

  We currently support the following filters: 'eq', 'neq', 'lt', 'lte', 'gt', 'gte', 'in'

  ## Examples

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages", "filter" => "subject=eq.hey"})
      {:ok, {"*", "public", "messages", [{"subject", "eq", "hey"}]}}

  `in` filter:

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages", "filter" => "subject=in.(hidee,ho)"})
      {:ok, {"*", "public", "messages", [{"subject", "in", "{hidee,ho}"}]}}

  no filter:

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages"})
      {:ok, {"*", "public", "messages", []}}

  only schema:

      iex> parse_subscription_params(%{"schema" => "public"})
      {:ok, {"*", "public", "*", []}}

  only table:

      iex> parse_subscription_params(%{"table" => "messages"})
      {:ok, {"*", "public", "messages", []}}

  An unsupported filter will respond with an error tuple:

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages", "filter" => "subject=like.hey"})
      {:error, ~s(Error parsing `filter` params: ["like", "hey"])}

  Catch `undefined` filters:

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages", "filter" => "undefined"})
      {:error, ~s(Error parsing `filter` params: ["undefined"])}

  Catch `missing params`:

      iex> parse_subscription_params(%{})
      {:error, ~s(No subscription params provided. Please provide at least a `schema` or `table` to subscribe to: %{})}

  """

  @spec parse_subscription_params(map()) :: {:ok, subscription_params} | {:error, binary()}
  def parse_subscription_params(params) do
    action_filter = action_filter(params)

    case params do
      %{"schema" => schema, "table" => table, "filter" => filter}
      when is_binary(schema) and is_binary(table) and is_binary(filter) ->
        with [col, rest] <- String.split(filter, "=", parts: 2),
             [filter_type, value] when filter_type in @filter_types <-
               String.split(rest, ".", parts: 2),
             {:ok, formatted_value} <- format_filter_value(filter_type, value) do
          {:ok, {action_filter, schema, table, [{col, filter_type, formatted_value}]}}
        else
          {:error, msg} ->
            {:error, "Error parsing `filter` params: #{msg}"}

          e ->
            {:error, "Error parsing `filter` params: #{inspect(e)}"}
        end

      %{"schema" => schema, "table" => table}
      when is_binary(schema) and is_binary(table) and not is_map_key(params, "filter") ->
        {:ok, {action_filter, schema, table, []}}

      %{"schema" => schema}
      when is_binary(schema) and not is_map_key(params, "table") and not is_map_key(params, "filter") ->
        {:ok, {action_filter, schema, "*", []}}

      %{"table" => table}
      when is_binary(table) and not is_map_key(params, "schema") and not is_map_key(params, "filter") ->
        {:ok, {action_filter, "public", table, []}}

      map when is_map_key(map, "user_token") or is_map_key(map, "auth_token") ->
        {:error,
         "No subscription params provided. Please provide at least a `schema` or `table` to subscribe to: <redacted>"}

      error ->
        {:error,
         "No subscription params provided. Please provide at least a `schema` or `table` to subscribe to: #{inspect(error)}"}
    end
  end

  defp action_filter(%{"event" => "*"}), do: "*"

  defp action_filter(%{"event" => event}) when is_binary(event) do
    case String.upcase(event) do
      "INSERT" -> "INSERT"
      "UPDATE" -> "UPDATE"
      "DELETE" -> "DELETE"
      _ -> "*"
    end
  end

  defp action_filter(_), do: "*"

  defp format_filter_value(filter, value) do
    case filter do
      "in" ->
        case Regex.run(~r/^\((.*)\)$/, value) do
          nil ->
            {:error, "`in` filter value must be wrapped by parentheses"}

          [_, new_value] ->
            {:ok, "{#{new_value}}"}
        end

      _ ->
        {:ok, value}
    end
  end
end
