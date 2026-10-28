defmodule SqlLogex.Deparse do
  @moduledoc """
  Prints a `SqlLogex.AST` back to the text Postgres's `pg_get_expr` produces.

  `to_string(Parser.parse(text)) == text` holds for every input: supported nodes print their
  canonical form and `{:unsupported, raw}` prints the raw text it holds. The parser only accepts
  text that is already canonical, so printing never normalises anything.
  """

  import Kernel, except: [to_string: 1]

  alias SqlLogex.AST

  # `quote_identifier` in ruleutils.c leaves a name bare only if it is lowercase letters, digits and
  # underscores, and is not a keyword other than an unreserved one. This list is every such keyword
  # of PG17 (`SELECT word FROM pg_get_keywords() WHERE catcode <> 'U'`); older servers print a few
  # of the newest ones (`json_*`, `merge_action`, `system_user`) bare, which no policy uses.
  @quoted_keywords ~w(
    all analyse analyze and any array as asc asymmetric both case cast check collate column
    constraint create current_catalog current_date current_role current_time current_timestamp
    current_user default deferrable desc distinct do else end except false fetch for foreign from
    grant group having in initially intersect into lateral leading limit localtime localtimestamp
    not null offset on only or order placing primary references returning select session_user some
    symmetric system_user table then to trailing true union unique user using variadic when where
    window with
    between bigint bit boolean char character coalesce dec decimal exists extract float greatest
    grouping inout int integer interval json json_array json_arrayagg json_exists json_object
    json_objectagg json_query json_scalar json_serialize json_table json_value least merge_action
    national nchar none normalize nullif numeric out overlay position precision real row setof
    smallint substring time timestamp treat trim values varchar xmlattributes xmlconcat xmlelement
    xmlexists xmlforest xmlnamespaces xmlparse xmlpi xmlroot xmlserialize xmltable
    authorization binary collation concurrently cross current_schema freeze full ilike inner is
    isnull join left like natural notnull outer overlaps right similar tablesample verbose
  )

  @doc """
  Prints `ast` as Postgres would.
  """
  @spec to_string(AST.t()) :: String.t()
  def to_string({:bool_expr, :and, args}), do: "(" <> Enum.map_join(args, " AND ", &to_string/1) <> ")"
  def to_string({:bool_expr, :or, args}), do: "(" <> Enum.map_join(args, " OR ", &to_string/1) <> ")"
  def to_string({:not, arg}), do: "(NOT " <> to_string(arg) <> ")"
  def to_string({:op, op, left, right}), do: "(" <> to_string(left) <> " " <> op <> " " <> to_string(right) <> ")"

  def to_string({:scalar_array_op, op, quantifier, left, right}) do
    "(" <> to_string(left) <> " " <> op <> " " <> quantifier(quantifier) <> " (" <> to_string(right) <> "))"
  end

  def to_string({:array, elements}), do: "ARRAY[" <> Enum.map_join(elements, ", ", &to_string/1) <> "]"
  def to_string({:null_test, :is_null, arg}), do: "(" <> to_string(arg) <> " IS NULL)"
  def to_string({:null_test, :is_not_null, arg}), do: "(" <> to_string(arg) <> " IS NOT NULL)"

  # Postgres prints a typed string, NULL or empty array without parentheses, anything else with.
  def to_string({:cast, {:const, :string, _} = arg, type}), do: to_string(arg) <> "::" <> type
  def to_string({:cast, {:const, :null} = arg, type}), do: to_string(arg) <> "::" <> type
  def to_string({:cast, {:array, []} = arg, type}), do: to_string(arg) <> "::" <> type
  def to_string({:cast, arg, type}), do: "(" <> to_string(arg) <> ")::" <> type

  def to_string({:const, :string, value}), do: "'" <> String.replace(value, "'", "''") <> "'"
  def to_string({:const, :number, raw}), do: raw
  def to_string({:const, :bool, value}), do: Kernel.to_string(value)
  def to_string({:const, :null}), do: "NULL"

  def to_string({:func, schema, name, args}) do
    qualifier = if schema, do: quote_ident(schema) <> ".", else: ""
    qualifier <> quote_ident(name) <> "(" <> Enum.map_join(args, ", ", &to_string/1) <> ")"
  end

  def to_string({:coalesce, args}), do: "COALESCE(" <> Enum.map_join(args, ", ", &to_string/1) <> ")"
  def to_string({:nullif, left, right}), do: "NULLIF(" <> to_string(left) <> ", " <> to_string(right) <> ")"
  def to_string({:column, name}), do: quote_ident(name)
  def to_string({:sublink, arg, nil}), do: "( SELECT " <> to_string(arg) <> ")"
  def to_string({:sublink, arg, as}), do: "( SELECT " <> to_string(arg) <> " AS " <> quote_ident(as) <> ")"
  def to_string({:unsupported, raw}), do: raw

  @doc """
  Quotes an identifier the way Postgres's `quote_identifier` does.
  """
  @spec quote_ident(String.t()) :: String.t()
  def quote_ident(name) do
    if needs_quotes?(name), do: ~s(") <> String.replace(name, ~s("), ~s("")) <> ~s("), else: name
  end

  @doc """
  Whether `name` must be double-quoted to be read back as the same identifier.
  """
  @spec needs_quotes?(String.t()) :: boolean()
  def needs_quotes?(name), do: not Regex.match?(~r/\A[a-z_][a-z0-9_]*\z/, name) or quoted_keyword?(name)

  for keyword <- @quoted_keywords do
    defp quoted_keyword?(unquote(keyword)), do: true
  end

  defp quoted_keyword?(_name), do: false

  defp quantifier(:any), do: "ANY"
  defp quantifier(:all), do: "ALL"
end
