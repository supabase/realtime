defmodule SqlLogex.Parser do
  # Longer text isn't parsed, see the moduledoc.
  @max_bytes 4_096

  @moduledoc """
  Parses the text `pg_get_expr` produces for a policy expression into a `SqlLogex.AST`.

  The input is Postgres's own canonical output, never hand-written SQL, so the grammar is exact:
  single spaces, every operator, `AND`/`OR`, `NOT`, null test and `ANY`/`ALL` in its own parentheses,
  and no precedence to resolve. Text that is not canonical is not accepted and becomes
  `{:unsupported, raw}`, so `SqlLogex.Deparse.to_string(parse(text)) == text` always holds.

  `parse/1` never raises and never returns an error. What it can't read becomes
  `{:unsupported, raw}` holding the exact source text, and only that part: in
  `(A AND B AND C)` an unreadable `B` leaves `A` and `C` parsed. Such a part runs up to the
  delimiter that ends its position, skipping over quoted literals and bracketed groups, so a `)`
  inside a string or a nested subquery doesn't end it.

  A part is also unsupported when it parses but isn't followed by a delimiter, so trailing junk
  never disappears silently: it takes the part it trails with it.

  Text longer than #{@max_bytes} bytes is `{:unsupported, text}` without running the grammar. The
  recovery path is quadratic in the nesting depth (measured: a 52 KB policy of 1500 nested
  `COALESCE(... COLLATE "C", 'a')` that Postgres 17 accepted took 3.1 s), and tenants control
  policy text. Real policy expressions are far smaller, the largest captured fixture is 200 bytes.
  The round trip above still holds.

  The grammar is NimbleParsec, compiled into this module. NimbleParsec is a compile-time
  dependency only.
  """

  import NimbleParsec

  alias SqlLogex.AST
  alias SqlLogex.Deparse

  # Characters Postgres allows in an operator name. Which operators exist is for the resolver.
  @op_chars [?+, ?-, ?*, ?/, ?<, ?>, ?=, ?~, ?!, ?@, ?#, ?%, ?^, ?&, ?|, ?`, ??]

  @doc """
  Parses `text` into an AST, with `{:unsupported, raw}` for whatever it can't read.
  """
  @spec parse(String.t()) :: AST.t()
  def parse(text) when is_binary(text) and byte_size(text) > @max_bytes, do: {:unsupported, text}

  def parse(text) when is_binary(text) do
    case top(text) do
      {:ok, [ast], "", _context, _line, _offset} -> ast
      _ -> {:unsupported, text}
    end
  end

  # Lexical pieces

  ident_start = [?a..?z, ?_]
  ident_rest = [?a..?z, ?0..?9, ?_]

  # An identifier as `quote_identifier` prints it. The unquoted form must not need quotes and the
  # quoted form must, or the text wouldn't deparse to itself.
  bare_ident =
    ascii_string(ident_start, 1)
    |> optional(ascii_string(ident_rest, min: 1))
    |> reduce({List, :to_string, []})
    |> post_traverse({:check_ident, [false]})

  quoted_ident =
    ignore(string(~s(")))
    |> times(choice([replace(string(~s("")), ~s(")), utf8_string([not: ?"], min: 1)]), min: 1)
    |> ignore(string(~s(")))
    |> reduce({List, :to_string, []})
    |> post_traverse({:check_ident, [true]})

  defcombinatorp :ident, choice([quoted_ident, bare_ident])

  # The same two shapes, kept verbatim, for type names.
  raw_bare_ident = ascii_string(ident_start, 1) |> optional(ascii_string(ident_rest, min: 1))
  raw_dquoted = string(~s(")) |> repeat(choice([string(~s("")), utf8_string([not: ?"], min: 1)])) |> string(~s("))
  raw_ident = choice([raw_dquoted, raw_bare_ident])

  digits = ascii_string([?0..?9], min: 1)

  # What follows `::`. Multi-word names (`double precision`, `timestamp with time zone`), a length
  # or precision, and array brackets all belong to it.
  defcombinatorp :type,
                 choice([string("double precision"), string("character varying"), string("bit varying"), raw_ident])
                 |> optional(string(".") |> concat(raw_ident))
                 |> optional(string("(") |> concat(digits) |> optional(string(",") |> concat(digits)) |> string(")"))
                 |> optional(choice([string(" with time zone"), string(" without time zone")]))
                 |> repeat(string("[]"))
                 |> reduce({List, :to_string, []})

  # Expressions

  string_const =
    ignore(string("'"))
    |> repeat(choice([replace(string("''"), "'"), utf8_string([not: ?'], min: 1)]))
    |> ignore(string("'"))
    |> reduce({:build_string_const, []})

  null_const = string("NULL") |> lookahead_not(ascii_char([?A..?Z, ?a..?z, ?0..?9, ?_])) |> replace({:const, :null})

  defcombinatorp :typed_literal,
                 choice([string_const, null_const])
                 |> optional(ignore(string("::")) |> parsec(:type))
                 |> reduce({:build_typed_literal, []})

  defcombinatorp :bool_const,
                 choice([
                   replace(string("true"), {:const, :bool, true}),
                   replace(string("false"), {:const, :bool, false})
                 ])
                 |> lookahead_not(ascii_char(ident_rest))

  defcombinatorp :number_const,
                 digits
                 |> optional(string(".") |> concat(digits))
                 |> reduce({:build_number_const, []})

  # An empty array is the only one Postgres prints with a cast: `ARRAY[]::text[]`.
  defcombinatorp :array,
                 ignore(string("ARRAY["))
                 |> optional(parsec(:operand) |> repeat(ignore(string(", ")) |> parsec(:operand)))
                 |> ignore(string("]"))
                 |> tag(:array)
                 |> optional(ignore(string("::")) |> parsec(:type))
                 |> post_traverse({:build_array, []})

  defcombinatorp :coalesce,
                 ignore(string("COALESCE("))
                 |> parsec(:operand)
                 |> repeat(ignore(string(", ")) |> parsec(:operand))
                 |> ignore(string(")"))
                 |> tag(:coalesce)

  defcombinatorp :nullif,
                 ignore(string("NULLIF("))
                 |> parsec(:operand)
                 |> ignore(string(", "))
                 |> parsec(:operand)
                 |> ignore(string(")"))
                 |> reduce({:build_nullif, []})

  # `name(args)` or `schema.name(args)`. A name with no parenthesis after it is a column.
  defcombinatorp :func,
                 parsec(:ident)
                 |> optional(ignore(string(".")) |> parsec(:ident))
                 |> ignore(string("("))
                 |> tag(optional(parsec(:operand) |> repeat(ignore(string(", ")) |> parsec(:operand))), :args)
                 |> ignore(string(")"))
                 |> reduce({:build_func, []})

  defcombinatorp :column,
                 parsec(:ident)
                 |> lookahead_not(choice([string("("), string(".")]))
                 |> unwrap_and_tag(:column)

  # `( SELECT expr)` or `( SELECT expr AS alias)`. With a FROM clause the expression is followed by
  # a newline rather than `)`, so those fail here and stay unsupported as a whole.
  defcombinatorp :sublink,
                 ignore(string("( SELECT "))
                 |> parsec(:expr)
                 |> optional(ignore(string(" AS ")) |> parsec(:ident))
                 |> ignore(string(")"))
                 |> reduce({:build_sublink, []})

  defcombinatorp :not_expr,
                 ignore(string("(NOT ")) |> parsec(:operand) |> ignore(string(")")) |> unwrap_and_tag(:not)

  # Everything else that starts with `(`. What follows the first operand says which form it is.
  defcombinatorp :paren_expr,
                 ignore(string("("))
                 |> parsec(:operand)
                 |> choice([
                   times(ignore(string(" AND ")) |> parsec(:operand), min: 1) |> ignore(string(")")) |> tag(:and),
                   times(ignore(string(" OR ")) |> parsec(:operand), min: 1) |> ignore(string(")")) |> tag(:or),
                   choice([replace(string(" IS NOT NULL"), :is_not_null), replace(string(" IS NULL"), :is_null)])
                   |> ignore(string(")"))
                   |> unwrap_and_tag(:null_test),
                   ignore(string(" "))
                   |> ascii_string(@op_chars, min: 1)
                   |> ignore(string(" "))
                   |> choice([
                     choice([replace(string("ANY"), :any), replace(string("ALL"), :all)])
                     |> ignore(string(" ("))
                     |> parsec(:operand)
                     |> ignore(string("))")),
                     parsec(:operand) |> ignore(string(")"))
                   ])
                   |> tag(:op),
                   ignore(string(")::")) |> parsec(:type) |> unwrap_and_tag(:cast)
                 ])
                 |> post_traverse({:build_paren, []})

  defcombinatorp :expr,
                 choice([
                   parsec(:sublink),
                   parsec(:not_expr),
                   parsec(:paren_expr),
                   parsec(:array),
                   parsec(:coalesce),
                   parsec(:nullif),
                   parsec(:typed_literal),
                   parsec(:bool_const),
                   parsec(:number_const),
                   parsec(:func),
                   parsec(:column)
                 ])

  # Recovery

  # What ends an unsupported run at nesting depth 0: the closer of the enclosing group, a separator,
  # or the next AND/OR/IS/operator. It is also what must follow a part for that part to count as parsed.
  defcombinatorp :stop,
                 choice([
                   string(")"),
                   string("]"),
                   string(","),
                   string(" AND "),
                   string(" OR "),
                   string(" IS "),
                   string(" ") |> ascii_string(@op_chars, min: 1) |> string(" ")
                 ])

  # The pieces of an unsupported run are matched and thrown away. The raw text is cut out of the
  # input afterwards (see `mark_run_start/5`), because accumulating it character by character makes
  # every enclosing group copy its contents, which is cubic over deeply nested input.
  skip_squoted = ignore(string("'") |> repeat(choice([string("''"), utf8_string([not: ?'], min: 1)])) |> string("'"))

  skip_dquoted =
    ignore(string(~s(")) |> repeat(choice([string(~s("")), utf8_string([not: ?"], min: 1)])) |> string(~s(")))

  # `(...)` or `[...]` with whatever is inside, quoted literals included.
  defcombinatorp :group,
                 ignore(
                   choice([
                     string("(") |> repeat(parsec(:run_unit)) |> string(")"),
                     string("[") |> repeat(parsec(:run_unit)) |> string("]")
                   ])
                 )

  defcombinatorp :run_unit,
                 choice([
                   skip_squoted,
                   skip_dquoted,
                   parsec(:group),
                   ignore(utf8_string([not: ?(, not: ?), not: ?[, not: ?], not: ?', not: ?"], min: 1))
                 ])

  defcombinatorp :unsupported,
                 empty()
                 |> post_traverse({:mark_run_start, []})
                 |> times(
                   lookahead_not(parsec(:stop))
                   |> choice([
                     skip_squoted,
                     skip_dquoted,
                     parsec(:group),
                     ignore(utf8_char(not: ?(, not: ?), not: ?[, not: ?], not: ?', not: ?"))
                   ]),
                   min: 1
                 )
                 |> post_traverse({:build_unsupported, []})

  # A part of a larger expression: parsed if it is followed by a delimiter, raw text otherwise.
  defcombinatorp :operand,
                 choice([
                   parsec(:expr) |> lookahead(choice([parsec(:stop), eos()])),
                   parsec(:unsupported)
                 ])

  defparsecp :top, parsec(:operand) |> eos()

  # Builders

  defp check_ident(rest, [name], context, _line, _offset, quoted?) do
    if Deparse.needs_quotes?(name) == quoted?,
      do: {rest, [name], context},
      else: {:error, "identifier not in the form Postgres prints"}
  end

  defp build_string_const(parts), do: {:const, :string, IO.iodata_to_binary(parts)}
  defp build_number_const(parts), do: {:const, :number, IO.iodata_to_binary(parts)}

  defp build_typed_literal([literal]), do: literal
  defp build_typed_literal([literal, type]), do: {:cast, literal, type}

  defp build_array(rest, [{:array, _} = array], context, _line, _offset), do: {rest, [array], context}

  defp build_array(rest, [type, {:array, []} = array], context, _line, _offset),
    do: {rest, [{:cast, array, type}], context}

  defp build_array(_rest, _acc, _context, _line, _offset), do: {:error, "cast on a non-empty array"}

  defp build_nullif([left, right]), do: {:nullif, left, right}

  defp build_func([name, {:args, args}]), do: {:func, nil, name, args}
  defp build_func([schema, name, {:args, args}]), do: {:func, schema, name, args}

  defp build_sublink([arg]), do: {:sublink, arg, nil}
  defp build_sublink([arg, as]), do: {:sublink, arg, as}

  # Remembers the input at the start of an unsupported run, so `build_unsupported/5` can cut the
  # run out of it by length. A run never contains another run, so one slot is enough.
  defp mark_run_start(rest, acc, context, _line, _offset), do: {rest, acc, Map.put(context, :run_start, rest)}

  defp build_unsupported(rest, acc, %{run_start: start} = context, _line, _offset) do
    raw = start |> binary_part(0, byte_size(start) - byte_size(rest)) |> :binary.copy()
    {rest, [{:unsupported, raw} | acc], context}
  end

  # The accumulator is in reverse: the form's tail, then the first operand.
  defp build_paren(rest, [{:and, more}, first], context, _line, _offset),
    do: {rest, [{:bool_expr, :and, [first | more]}], context}

  defp build_paren(rest, [{:or, more}, first], context, _line, _offset),
    do: {rest, [{:bool_expr, :or, [first | more]}], context}

  defp build_paren(rest, [{:null_test, kind}, first], context, _line, _offset),
    do: {rest, [{:null_test, kind, first}], context}

  defp build_paren(rest, [{:op, [op, right]}, left], context, _line, _offset),
    do: {rest, [{:op, op, left, right}], context}

  defp build_paren(rest, [{:op, [op, quantifier, right]}, left], context, _line, _offset),
    do: {rest, [{:scalar_array_op, op, quantifier, left, right}], context}

  # Postgres prints these three without parentheses, so `('x')::text` isn't something it produced.
  defp build_paren(_rest, [{:cast, _type}, {:const, :string, _}], _context, _line, _offset),
    do: {:error, "parenthesised cast of a string"}

  defp build_paren(_rest, [{:cast, _type}, {:const, :null}], _context, _line, _offset),
    do: {:error, "parenthesised cast of NULL"}

  defp build_paren(_rest, [{:cast, _type}, {:array, []}], _context, _line, _offset),
    do: {:error, "parenthesised cast of an empty array"}

  defp build_paren(rest, [{:cast, type}, first], context, _line, _offset),
    do: {rest, [{:cast, first, type}], context}
end
