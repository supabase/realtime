defmodule RealtimeFilterParser do
  @moduledoc """
  Parses Supabase realtime filter strings such as:

      "date=eq.2026-02-03,published_at=not.is.null,area=eq.Oslo\\, Norway,id=in.(1,2,3)"

  Splitting rules:

    • The filter string is split on commas.
    • A comma can be escaped using '\\,' and will then be treated as part of the value.
      Example:
          area=eq.Oslo\\, Norway
      becomes:
          {"area", "eq", "Oslo, Norway"}

    • Commas inside parentheses are NOT treated as separators.
      Example:
          id=in.(1,2,3)

  Supported operators:

      eq, neq, lt, lte, gt, gte, in, isnull, notnull

  Special cases:

      is.null      → {"column", "isnull", nil}
      not.is.null  → {"column", "notnull", nil}

  Returns:

      {:ok, [{column, operator, value}, ...]}
      {:error, reason}
  """

  @filter_types ["eq", "neq", "lt", "lte", "gt", "gte", "in", "isnull", "notnull"]

  @spec parse_filter(String.t() | nil) ::
          {:ok, list({String.t(), String.t(), any()})} | {:error, String.t()}
  def parse_filter(nil), do: {:ok, []}
  def parse_filter(""), do: {:ok, []}

  def parse_filter(filter) when is_binary(filter) do
    with parts when is_list(parts) <- split_filter(filter),
         {:ok, filters} <- parse_parts(parts) do
      {:ok, filters}
    else
      {:error, _} = err -> err
      other -> {:error, "unexpected parse error: #{inspect(other)}"}
    end
  end

  # ------------------------------------------------------------
  # Splitting logic:
  # - split on commas unless escaped: '\,'
  # - do not split on commas inside parentheses (for in.(...))
  # - unescape '\,' -> ',' in each resulting part
  # ------------------------------------------------------------

  @spec split_filter(String.t()) :: [String.t()]
  defp split_filter(filter) do
    filter
    |> String.graphemes()
    |> do_split([], "", 0, false)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&String.replace(&1, "\\,", ","))
  end

  # acc: list of completed parts (reversed)
  # buf: current part buffer
  # paren_depth: nesting depth of parentheses
  # escaped: whether previous char was '\'
  defp do_split([], acc, buf, _paren_depth, _escaped),
    do: Enum.reverse([buf | acc])

  # split only when comma is outside parentheses and not escaped
  defp do_split(["," | rest], acc, buf, 0, false) do
    do_split(rest, [buf | acc], "", 0, false)
  end

  # backslash means next char is "escaped" for splitting purposes (we keep the backslash)
  defp do_split(["\\" | rest], acc, buf, paren_depth, _escaped) do
    do_split(rest, acc, buf <> "\\", paren_depth, true)
  end

  defp do_split(["(" | rest], acc, buf, paren_depth, _escaped) do
    do_split(rest, acc, buf <> "(", paren_depth + 1, false)
  end

  defp do_split([")" | rest], acc, buf, paren_depth, _escaped) do
    do_split(rest, acc, buf <> ")", max(paren_depth - 1, 0), false)
  end

  defp do_split([c | rest], acc, buf, paren_depth, _escaped) do
    do_split(rest, acc, buf <> c, paren_depth, false)
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

          case parse_op_and_value(rest) do
            {:ok, filter_type, raw_value} ->
              if filter_type in @filter_types do
                with {:ok, formatted} <- format_filter_value(filter_type, raw_value) do
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

            {:error, reason} ->
              {:halt, {:error, "failed to parse filter '#{part}': #{reason}"}}
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

  # "is.null"     => {"isnull", nil}
  # "not.is.null" => {"notnull", nil}
  # "<op>.<value>" => {op, value}   (value left untouched; quotes untouched)
  @spec parse_op_and_value(String.t()) :: {:ok, String.t(), any()} | {:error, String.t()}
  defp parse_op_and_value(rest) when is_binary(rest) do
    rest = String.trim(rest)

    case String.split(rest, ".", parts: 3) do
      ["is", "null"] ->
        {:ok, "isnull", nil}

      ["not", "is", "null"] ->
        {:ok, "notnull", nil}

      [filter_type, raw_value] ->
        {:ok, filter_type, raw_value}

      _ ->
        {:error, "invalid filter format, expected 'is.null', 'not.is.null', or '<op>.<value>'"}
    end
  end

  # ------------------------------------------------------------
  # Value formatting
  # ------------------------------------------------------------

  @spec format_filter_value(String.t(), any()) :: {:ok, any()} | {:error, String.t()}
  defp format_filter_value(filter, value) do
    case filter do
      "in" ->
        case Regex.run(~r/^\((.*)\)$/, value) do
          nil ->
            {:error, "`in` filter value must be wrapped by parentheses"}

          [_, new_value] ->
            {:ok, "{#{new_value}}"}
        end

      "isnull" ->
        {:ok, nil}

      "notnull" ->
        {:ok, nil}

      _ ->
        {:ok, value}
    end
  end
end
