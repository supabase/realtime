defmodule Extensions.PostgresCdcRls.Subscriptions do
  @moduledoc """
  This module consolidates subscriptions handling
  """
  use Realtime.Logs

  import Postgrex, only: [transaction: 3, query: 3, rollback: 2]

  @type conn() :: Postgrex.conn()
  @type filter :: {binary, binary, binary}
  @type subscription_params ::
          {action_filter :: binary, schema :: binary, table :: binary, [filter]}
  @type subscription_list :: [
          %{id: binary, claims: map, subscription_params: subscription_params}
        ]

  @filter_types [
    "eq",
    "neq",
    "lt",
    "lte",
    "gt",
    "gte",
    "in",
    "like",
    "ilike",
    "is"
  ]

  @not_op_map %{
    "eq" => "neq",
    "neq" => "eq",
    "lt" => "gte",
    "lte" => "gt",
    "gt" => "lte",
    "gte" => "lt",
    "in" => "not_in",
    "like" => "not_like",
    "ilike" => "not_ilike",
    "is" => "not_is"
  }

  @spec create(conn(), String.t(), subscription_list, pid(), pid()) ::
          {:ok, Postgrex.Result.t()}
          | {:error, Exception.t() | {:exit, term} | {:subscription_insert_failed, String.t()}}

  def create(conn, publication, subscription_list, manager, caller) do
    opts = [timeout: 10_000]

    transaction(
      conn,
      fn conn ->
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
      end,
      opts
    )
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

  @spec delete(conn(), String.t()) :: {:ok, Postgrex.Result.t()} | {:error, any()}
  def delete(conn, id) do
    Logger.debug("Delete subscription")
    sql = "delete from realtime.subscription where subscription_id = $1"

    case query(conn, sql, [id]) do
      {:error, reason} ->
        log_error("SubscriptionDeletionFailed", reason)
        {:error, reason}

      result ->
        result
    end
  catch
    :exit, reason ->
      log_error("SubscriptionDeletionFailed", {:exit, reason})
      {:error, {:exit, reason}}
  end

  @spec delete_all(conn()) :: :ok
  def delete_all(conn) do
    Logger.debug("Delete all subscriptions")

    case query(conn, "delete from realtime.subscription;", []) do
      {:ok, _} -> :ok
      {:error, reason} -> log_error("SubscriptionDeletionFailed", reason)
    end
  catch
    :exit, reason -> log_error("SubscriptionDeletionFailed", {:exit, reason})
  end

  @spec delete_multi(conn(), [Ecto.UUID.t()]) ::
          {:ok, Postgrex.Result.t()} | {:error, Exception.t()}
  def delete_multi(conn, ids) do
    Logger.debug("Delete multi ids subscriptions")
    sql = "delete from realtime.subscription where subscription_id = ANY($1::uuid[])"
    query(conn, sql, [ids])
  end

  @spec delete_all_if_table_exists(conn()) :: :ok
  def delete_all_if_table_exists(conn) do
    case query(
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
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> log_error("SubscriptionCleanupFailed", reason)
    end
  catch
    :exit, reason -> log_error("SubscriptionCleanupFailed", {:exit, reason})
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

  We currently support the following filters: 'eq', 'neq', 'lt', 'lte', 'gt', 'gte', 'in', 'like', 'ilike', 'is'.
  Negated variants are expressed with the `not.` prefix: `not.eq`, `not.lt`, `not.in`, `not.like`, `not.ilike`, `not.is`, etc.

  Multiple filters can be combined with commas and are applied as AND conditions:
  `"col1=eq.val,col2=gt.5"` means `col1 = val AND col2 > 5`.

  ## Examples

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages", "filter" => "subject=eq.hey"})
      {:ok, {"*", "public", "messages", [{"subject", "eq", "hey"}]}}

  `in` filter:

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages", "filter" => "subject=in.(hidee,ho)"})
      {:ok, {"*", "public", "messages", [{"subject", "in", "{hidee,ho}"}]}}

  AND composition — multiple filters separated by commas:

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages", "filter" => "id=gt.0,id=lt.100"})
      {:ok, {"*", "public", "messages", [{"id", "gt", "0"}, {"id", "lt", "100"}]}}

  empty or whitespace-only filter string is treated as no filter:

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages", "filter" => ""})
      {:ok, {"*", "public", "messages", []}}

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages", "filter" => "   "})
      {:ok, {"*", "public", "messages", []}}

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

      iex> parse_subscription_params(%{"schema" => "public", "table" => "messages", "filter" => "subject=fts.hey"})
      {:error, ~s(Error parsing `filter` params: ["fts", "hey"])}

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
        case parse_filters(filter) do
          {:ok, filters} -> {:ok, {action_filter, schema, table, filters}}
          {:error, reason} -> {:error, "Error parsing `filter` params: #{reason}"}
        end

      %{"schema" => schema, "table" => table}
      when is_binary(schema) and is_binary(table) and not is_map_key(params, "filter") ->
        {:ok, {action_filter, schema, table, []}}

      %{"schema" => schema}
      when is_binary(schema) and not is_map_key(params, "table") and
             not is_map_key(params, "filter") ->
        {:ok, {action_filter, schema, "*", []}}

      %{"table" => table}
      when is_binary(table) and not is_map_key(params, "schema") and
             not is_map_key(params, "filter") ->
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

  defp parse_filters(filter) when is_binary(filter) do
    case String.trim(filter) do
      "" -> {:ok, []}
      trimmed -> scan(trimmed, trimmed, 0, 0, 0, false, [])
    end
  end

  # Reached end of binary — parse the final segment
  defp scan(<<>>, orig, start, len, _depth, _quoted, acc) do
    case parse_segment(binary_part(orig, start, len)) do
      {:ok, parsed} -> {:ok, Enum.reverse([parsed | acc])}
      {:error, _} = e -> e
    end
  end

  # Toggle quoted mode on double-quote; parens and commas have no special meaning while quoted
  defp scan(<<"\"", rest::binary>>, orig, start, len, depth, quoted, acc) do
    scan(rest, orig, start, len + 1, depth, not quoted, acc)
  end

  defp scan(<<"(", rest::binary>>, orig, start, len, depth, false = quoted, acc) do
    scan(rest, orig, start, len + 1, depth + 1, quoted, acc)
  end

  defp scan(<<")", rest::binary>>, orig, start, len, depth, false = quoted, acc) do
    scan(rest, orig, start, len + 1, max(0, depth - 1), quoted, acc)
  end

  # Comma at depth 0 and not inside quotes — segment boundary
  defp scan(<<",", rest::binary>>, orig, start, len, 0, false, acc) do
    case parse_segment(binary_part(orig, start, len)) do
      {:ok, parsed} -> scan(rest, orig, start + len + 1, 0, 0, false, [parsed | acc])
      {:error, _} = e -> e
    end
  end

  defp scan(<<_::8, rest::binary>>, orig, start, len, depth, quoted, acc) do
    scan(rest, orig, start, len + 1, depth, quoted, acc)
  end

  defp parse_segment(segment) do
    case String.trim(segment) do
      "" ->
        {:error, "filter must not contain empty segments (check for extra commas)"}

      trimmed ->
        with [col, rest] <- String.split(trimmed, "=", parts: 2),
             {:ok, filter_type, value} <- parse_filter_rest(rest),
             {:ok, formatted_value} <- format_filter_value(filter_type, value) do
          {:ok, {col, filter_type, formatted_value}}
        else
          {:error, msg} -> {:error, msg}
          e -> {:error, inspect(e)}
        end
    end
  end

  defp parse_filter_rest("not." <> rest) do
    case String.split(rest, ".", parts: 2) do
      [raw_op, value] ->
        case @not_op_map[raw_op] do
          nil -> {:error, "not.#{raw_op} is not a supported operator"}
          op -> {:ok, op, value}
        end

      _ ->
        {:error, inspect("not." <> rest)}
    end
  end

  defp parse_filter_rest(rest) do
    case String.split(rest, ".", parts: 2) do
      [filter_type, value] when filter_type in @filter_types -> {:ok, filter_type, value}
      other -> {:error, inspect(other)}
    end
  end

  defp format_filter_value(op, value) when op in ["in", "not_in"] do
    size = byte_size(value)

    if size >= 2 and binary_part(value, 0, 1) == "(" and binary_part(value, size - 1, 1) == ")" do
      {:ok, "{" <> binary_part(value, 1, size - 2) <> "}"}
    else
      {:error, "`#{op}` filter value must be wrapped by parentheses"}
    end
  end

  defp format_filter_value(_filter, "\"" <> rest) do
    size = byte_size(rest)

    if size >= 1 and binary_part(rest, size - 1, 1) == "\"" do
      {:ok, binary_part(rest, 0, size - 1)}
    else
      {:error, "unmatched double-quote in filter value"}
    end
  end

  defp format_filter_value(_filter, value), do: {:ok, value}
end
