defmodule RealtimeFilterParser do
  @moduledoc """
  Parse Supabase realtime filter strings like:

    "date=eq.2026-02-03,published_at=not.is.null,area=eq.\"Oslo, Norway\",id=in.(1,2,3)"

  Returns `{:ok, filters}` where filters is a list of `{column, operator, value}` tuples.

  Special-cases:
    - "is.null"     -> {"<col>", "null", nil}
    - "not.is.null" -> {"<col>", "nnull", nil}
    - "in.(a,b)"    -> {"<col>", "in", "{a,b}"}
  """

  @filter_types ["eq", "neq", "lt", "lte", "gt", "gte", "in"]

  @spec parse_filter(String.t() | nil) ::
          {:ok, list({String.t(), String.t(), any()})} | {:error, String.t()}
  def parse_filter(nil), do: {:ok, []}
  def parse_filter(""), do: {:ok, []}

  def parse_filter(filter) when is_binary(filter) do
    with parts when is_list(parts) <- split_on_unquoted_commas(filter),
         {:ok, filters} <- parse_parts(parts) do
      {:ok, filters}
    else
      {:error, _} = err -> err
      other -> {:error, "unexpected parse error: #{inspect(other)}"}
    end
  end

  # ------------------------------------------------------------
  # Splitting logic (comma, but not inside quoted strings or parentheses)
  # ------------------------------------------------------------
  @spec split_on_unquoted_commas(String.t()) :: [String.t()]
  defp split_on_unquoted_commas(s) do
    s
    |> String.graphemes()
    |> do_split([], "", nil, 0, false)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  # acc        - completed parts (reversed)
  # buf        - current buffer
  # quote      - current quote char (" or ') or nil
  # paren_depth- nesting level of parentheses (0 = outside)
  # escape     - whether previous char was backslash inside quotes
  defp do_split([], acc, buf, _quote, _paren_depth, _escape),
    do: Enum.reverse([buf | acc])

  # Split only when we see a comma that is outside quotes and with no open parentheses.
  defp do_split(["," | rest], acc, buf, nil, 0, false) do
    do_split(rest, [buf | acc], "", nil, 0, false)
  end

  defp do_split([c | rest], acc, buf, quote, paren_depth, escape) do
    cond do
      # inside quotes and previous char was escape -> append char literally
      quote in ["\"", "'"] and escape ->
        do_split(rest, acc, buf <> c, quote, paren_depth, false)

      # inside quotes and see backslash -> mark escape
      quote in ["\"", "'"] and c == "\\" ->
        do_split(rest, acc, buf <> c, quote, paren_depth, true)

      # closing quote (matches current) -> append and leave quote context
      quote in ["\"", "'"] and c == quote ->
        do_split(rest, acc, buf <> c, nil, paren_depth, false)

      # inside quotes, normal char
      quote in ["\"", "'"] ->
        do_split(rest, acc, buf <> c, quote, paren_depth, false)

      # not in quotes, see an opening quote -> enter quote context
      c in ["\"", "'"] ->
        do_split(rest, acc, buf <> c, c, paren_depth, false)

      # not in quotes, opening parenthesis increments depth
      c == "(" ->
        do_split(rest, acc, buf <> c, quote, paren_depth + 1, false)

      # not in quotes, closing parenthesis decrements depth (but never below 0)
      c == ")" ->
        new_depth = max(paren_depth - 1, 0)
        do_split(rest, acc, buf <> c, quote, new_depth, false)

      # any other char outside quotes/parentheses -> append
      true ->
        do_split(rest, acc, buf <> c, quote, paren_depth, false)
    end
  end

  # ------------------------------------------------------------
  # Parsing logic
  # ------------------------------------------------------------
  @spec parse_parts([String.t()]) ::
          {:ok, list({String.t(), String.t(), any()})} | {:error, String.t()}
  defp parse_parts(parts) do
    parts
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case String.split(part, "=", parts: 2) do
        [col, rest] ->
          col = String.trim(col)

          cond do
            rest == "is.null" ->
              {:cont, {:ok, [{col, "null", nil} | acc]}}

            rest == "not.is.null" ->
              {:cont, {:ok, [{col, "nnull", nil} | acc]}}

            true ->
              case String.split(rest, ".", parts: 2) do
                [filter_type, raw_value] ->
                  if filter_type in @filter_types do
                    with {:ok, extracted} <- extract_value(raw_value),
                         {:ok, formatted} <- format_filter_value(filter_type, extracted) do
                      {:cont, {:ok, [{col, filter_type, formatted} | acc]}}
                    else
                      {:error, reason} ->
                        {:halt, {:error, "failed to parse filter '#{part}': #{reason}"}}
                    end
                  else
                    {:halt,
                     {:error,
                      "unsupported filter type '#{filter_type}' for part: '#{part}'. supported: #{inspect(@filter_types)}"}}
                  end

                _ ->
                  {:halt, {:error, "invalid filter format for '#{part}', expected '<op>.<value>'"}}
              end
          end

        _ ->
          {:halt, {:error, "missing '=' in filter part: '#{part}'"}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      other -> other
    end
  end

  # ------------------------------------------------------------
  # Value extraction + formatting
  # ------------------------------------------------------------
  @spec extract_value(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  defp extract_value(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      quoted?(value, "\"") ->
        inside = String.slice(value, 1..-2)
        {:ok, unescape_inside(inside)}

      quoted?(value, "'") ->
        inside = String.slice(value, 1..-2)
        {:ok, unescape_inside(inside)}

      true ->
        {:ok, value}
    end
  end

  defp quoted?(value, q) do
    String.starts_with?(value, q) and String.ends_with?(value, q)
  end

  defp unescape_inside(s) do
    s
    |> String.replace(~S(\\\"), "\"")
    |> String.replace(~S(\\'), "'")
    |> String.replace(~S(\\\\), "\\")
  end

  # ------------------------------------------------------------
  # format_filter_value/2 (incorporated)
  # ------------------------------------------------------------
  @spec format_filter_value(String.t(), any()) ::
          {:ok, any()} | {:error, String.t()}
  defp format_filter_value(filter, value) do
    case filter do
      "in" ->
        case Regex.run(~r/^\((.*)\)$/, value) do
          nil ->
            {:error, "`in` filter value must be wrapped by parentheses"}

          [_, new_value] ->
            {:ok, "{#{new_value}}"}
        end

      "null" ->
        {:ok, nil}

      "nnull" ->
        {:ok, nil}

      _ ->
        {:ok, value}
    end
  end
end
