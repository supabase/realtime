defmodule SqlLogex.Catalog do
  @moduledoc """
  The function definitions the evaluator knows how to inline, recognised by fingerprint.

  A policy that calls `auth.uid()` runs whatever body the tenant's database has under that name,
  and tenants can change it. So a call is only inlined if the tenant's definition matches a known
  one exactly:

    * `language` is `sql`, `volatility` is `s` (stable), `security_definer` is `false`, and
      `config` is `nil`, so the function runs as the caller with no settings of its own
    * `return_type` is the expected one
    * the normalised `source` is equal to the normalised known body (see `normalize/1`)

  Anything else is `:error`, and the call stays unsupported. That includes the older supabase/auth
  versions of `auth.uid()` (migrations 20211124214934 and 20211202183645): we only know the
  bodies listed here, and a body we don't know is never assumed to behave like one we do.

  Definitions are maps shaped like the `functions` entries in `test/fixtures/*/catalog.exs`:
  `schema`, `name`, `language`, `volatility`, `security_definer`, `config`, `return_type` and
  `source`. The functions take no arguments.

  An inlined body is IR built from the same primitives the operators use, so evaluating it reads
  only `{:setting, name}`, exactly as Postgres does when it inlines a SQL function.
  """

  alias SqlLogex.IR
  alias SqlLogex.Jsonb
  alias SqlLogex.Value

  @type type :: :text | :uuid | :jsonb

  @topic "select nullif(current_setting('realtime.topic', true), '')::text;"

  # The versions in the supabase/postgres image.
  @uid_legacy "select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;"
  @role_legacy "select nullif(current_setting('request.jwt.claim.role', true), '')::text;"

  # supabase/auth migration 20220224000811, which production projects run.
  @uid_supabase_auth """
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
  """

  @role_supabase_auth """
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
  )::text
  """

  # supabase/auth migration 20220531120530.
  @jwt_supabase_auth """
  select
    coalesce(
        nullif(current_setting('request.jwt.claim', true), ''),
        nullif(current_setting('request.jwt.claims', true), '')
    )::jsonb
  """

  # {schema, name, return type, its type, known source, the body as IR}
  defp known do
    [
      {"realtime", "topic", "text", :text, @topic, nullif_empty("realtime.topic")},
      {"auth", "uid", "uuid", :uuid, @uid_legacy, call(Value, :uuid_in, [nullif_empty("request.jwt.claim.sub")])},
      {"auth", "uid", "uuid", :uuid, @uid_supabase_auth,
       call(Value, :uuid_in, [claim_or_field("request.jwt.claim.sub", "sub")])},
      {"auth", "role", "text", :text, @role_legacy, nullif_empty("request.jwt.claim.role")},
      {"auth", "role", "text", :text, @role_supabase_auth, claim_or_field("request.jwt.claim.role", "role")},
      {"auth", "jwt", "jsonb", :jsonb, @jwt_supabase_auth,
       call(Jsonb, :parse, [{:coalesce, [claim_singular(), claims()]}])}
    ]
  end

  @doc """
  The IR and type of the body of `definition`, if it matches a known function.

  The result is `{:ok, {ir, type}}` when schema, name, language, volatility, `security_definer`,
  `config`, return type and normalised source all match, otherwise `:error`. A body that contains
  `--` or `/*` never matches, so a comment can't hide a change.
  """
  @spec inline(map()) :: {:ok, {IR.t(), type}} | :error
  def inline(%{} = definition) do
    source = Map.get(definition, :source)

    if plain_function?(definition) and is_binary(source) and not has_comment?(source) do
      normalized = normalize(source)

      Enum.find_value(known(), :error, fn {schema, name, return_type, type, known_source, ir} ->
        if Map.get(definition, :schema) == schema and Map.get(definition, :name) == name and
             Map.get(definition, :return_type) == return_type and normalize(known_source) == normalized do
          {:ok, {ir, type}}
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

  ## IR building blocks

  defp call(module, function, args), do: {:apply, module, function, args}

  # nullif(current_setting(name, true), '')
  defp nullif_empty(name), do: call(Value, :nullif, [{:setting, name}, {:lit, {:text, ""}}])

  defp claims, do: nullif_empty("request.jwt.claims")

  # `request.jwt.claim` (singular) is not one of the settings Realtime sets, so on its connections
  # current_setting returns NULL (never set) or '' (set earlier on that backend), and
  # nullif(..., '') turns both into NULL. This argument is therefore always NULL.
  defp claim_singular, do: {:lit, nil}

  # coalesce(nullif(current_setting(setting, true), ''),
  #          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> field))
  #
  # Both arguments count, see `SqlLogex.Value.coalesce/1`: claims that don't parse make it unsupported
  # even when the setting is set.
  defp claim_or_field(setting, field) do
    {:coalesce,
     [
       nullif_empty(setting),
       call(Jsonb, :object_field_text, [call(Jsonb, :parse, [claims()]), {:lit, {:text, field}}])
     ]}
  end
end
