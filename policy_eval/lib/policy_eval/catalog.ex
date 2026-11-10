defmodule PolicyEval.Catalog do
  @moduledoc """
  Recognises function definitions by fingerprint, so that a call can be inlined.

  A policy that calls `auth.uid()` runs whatever body the database has under that name, and the
  policy author can change it. So a call is only inlined if the definition in the database
  matches a known one exactly:

    * `language` is `sql`, `volatility` is `s` (stable), `security_definer` is `false`, and
      `config` is `nil`, so the function runs as the caller with no settings of its own
    * `return_type` is the expected one
    * the normalised `source` is equal to the normalised known body (see `normalize/1`)

  Anything else is `:error`, and the call stays unsupported. The known definitions come from the
  profile (`PolicyEval.Profile`, built with `PolicyEval.KnownFunction`), and only those are inlined.

  Definitions are maps shaped like the `functions` entries in `test/fixtures/*/catalog.exs`:
  `schema`, `name`, `language`, `volatility`, `security_definer`, `config`, `return_type` and
  `source`. The functions take no arguments.

  An inlined body is IR built from the same primitives the operators use, so evaluating it reads
  only `{:setting, name}`, exactly as Postgres does when it inlines a SQL function.
  """

  alias PolicyEval.IR
  alias PolicyEval.KnownFunction

  @type type :: :text | :uuid | :jsonb

  @doc """
  The IR and type of the body of `definition`, if it matches one of `known`, the `functions` of a
  profile.

  The result is `{:ok, {ir, type}}` when schema, name, language, volatility, `security_definer`,
  `config`, return type and normalised source all match, otherwise `:error`. A body that contains
  `--` or `/*` never matches, so a comment can't hide a change.
  """
  @spec inline(map(), [KnownFunction.t()]) :: {:ok, {IR.t(), type}} | :error
  def inline(%{} = definition, known) when is_list(known) do
    source = Map.get(definition, :source)

    if plain_function?(definition) and is_binary(source) and not has_comment?(source) do
      normalized = normalize(source)

      Enum.find_value(known, :error, fn function ->
        if Map.get(definition, :schema) == function.schema and Map.get(definition, :name) == function.name and
             Map.get(definition, :return_type) == function.return_type and normalize(function.source) == normalized do
          {:ok, {function.ir, function.type}}
        end
      end)
    else
      :error
    end
  end

  defp plain_function?(definition) do
    Map.get(definition, :language) == "sql" and Map.get(definition, :volatility) == "s" and
      Map.get(definition, :security_definer) == false and Map.get(definition, :config) == nil
  end

  defp has_comment?(source), do: String.contains?(source, ["--", "/*"])

  @whitespace ~r/[ \t\n\r\f]+/
  @around_punctuation ~r/ ?([(),]) ?/
  @edge_whitespace ~r/\A[ \t\n\r\f]+|[ \t\n\r\f]+\z/

  @doc """
  Normalises a function body so that bodies differing only in layout compare equal.

  Outside single-quoted string literals, whitespace runs become one space and spaces next to `(`,
  `)` and `,` are removed. Then the ends are trimmed and one trailing `;` is dropped. String
  literals are kept byte for byte, and case is not touched.

  The only characters that change are whitespace, and never inside a literal, so two bodies with
  the same normal form have the same tokens and literals. A body Postgres would read differently
  because of quoting this doesn't track (`E'..'`, `$$..$$`, `"..."`) keeps its quoting characters
  and so can't equal the normal form of a known body, which has none of them.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize(source) when is_binary(source) do
    # Splitting on the quote puts code at even positions and literal contents at odd ones. A doubled
    # quote inside a literal becomes two adjacent literals, which joins back to the same text. An
    # odd number of quotes leaves an unterminated literal last, which is kept as it is.
    parts = :binary.split(source, "'", [:global])
    last = length(parts) - 1

    parts
    |> Enum.with_index()
    |> Enum.map(fn
      {code, index} when rem(index, 2) == 0 -> normalize_code(code)
      {literal, ^last} -> "'" <> literal
      {literal, _index} -> "'" <> literal <> "'"
    end)
    |> IO.iodata_to_binary()
    |> trim()
    |> drop_semicolon()
  end

  defp normalize_code(code) do
    @whitespace
    |> Regex.replace(code, " ")
    |> then(&Regex.replace(@around_punctuation, &1, "\\1"))
  end

  defp trim(text), do: Regex.replace(@edge_whitespace, text, "")

  defp drop_semicolon(text) do
    if String.ends_with?(text, ";") do
      text |> binary_part(0, byte_size(text) - 1) |> trim()
    else
      text
    end
  end
end
