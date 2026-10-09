defmodule SqlLogex.Value do
  @moduledoc """
  Postgres value primitives: one function per Postgres function or operator the evaluator needs.

  Values are `{:text, binary}`, `{:uuid, <<_::128>>}`, `{:jsonb, term}` (see `SqlLogex.Jsonb`),
  a bare `true`/`false`, and `nil` for SQL NULL. Every function returns a value, `nil`, or
  `{:unsupported, reason}`. Where Postgres raises, the reason is `{:raises, sqlstate_name, detail}`,
  so the caller asks the database instead.

  Arguments are already evaluated, so any of them may itself be `{:unsupported, _}`. Postgres
  evaluates all arguments of a function before calling it, so unless stated otherwise the first
  unsupported argument is returned unchanged, even when another argument is `nil`.

  These functions assume a UTF-8 database with a deterministic default collation, and text values
  without NUL bytes (Postgres text can't hold them).
  """

  @type t :: {:text, binary()} | {:uuid, <<_::128>>} | {:jsonb, term()} | boolean() | nil
  @type result :: t | {:unsupported, term()}

  # Characters that make a pattern more than a literal in a Postgres advanced regular expression.
  # `***` (director) and `(?` (embedded options) are covered by `*` and `(`.
  @regex_meta ["|", "*", "+", "?", "(", ")", ".", "^", "$", "\\", "[", "{"]

  defguardp is_hex(c) when c in ?0..?9 or c in ?a..?f or c in ?A..?F

  ## Text

  @doc """
  `text = text` (`texteq`, src/backend/utils/adt/varlena.c). Strict.

  Under a deterministic collation Postgres compares bytes, so this is `==`.
  """
  @spec text_eq(result, result) :: result
  def text_eq(a, b), do: strict2(a, b, fn {:text, x}, {:text, y} -> x == y end)

  @doc "`text <> text` (`textne`, src/backend/utils/adt/varlena.c). Strict."
  @spec text_ne(result, result) :: result
  def text_ne(a, b), do: strict2(a, b, fn {:text, x}, {:text, y} -> x != y end)

  @doc "`text || text` (`textcat`, src/backend/utils/adt/varlena.c). Strict."
  @spec textcat(result, result) :: result
  def textcat(a, b), do: strict2(a, b, fn {:text, x}, {:text, y} -> {:text, x <> y} end)

  @doc """
  `text || uuid` (`textanycat`, oid 2003 in src/include/catalog/pg_proc.dat). Strict.

  The function body is `select $1 || $2::text`, so the uuid goes through `uuid_out`. Only uuid is
  implemented; any other right-hand type is unsupported.
  """
  @spec textanycat(result, result) :: result
  def textanycat(a, b) do
    strict2(a, b, fn
      {:text, x}, {:uuid, _} = uuid -> {:text, x <> format_uuid(uuid)}
      {:text, _}, _other -> {:unsupported, :textanycat_non_uuid}
    end)
  end

  @doc """
  `text = ANY (ARRAY[...])` (`ExecEvalScalarArrayOp`, src/backend/executor/execExprInterp.c).

  `elems` are the already-evaluated array elements. The array constructor evaluates every element
  before the comparison, so an unsupported element is returned even if an earlier one matches.
  After that:

    * an empty array gives `false`, even for a NULL `lhs`
    * a NULL `lhs` against a non-empty array gives `nil`
    * any equal element gives `true`
    * otherwise `nil` if some element is NULL, else `false`
  """
  @spec text_eq_any(result, [result]) :: result
  def text_eq_any(lhs, elems) when is_list(elems) do
    case Enum.find([lhs | elems], &match?({:unsupported, _}, &1)) do
      nil -> eq_any(lhs, elems)
      unsupported -> unsupported
    end
  end

  defp eq_any(_lhs, []), do: false
  defp eq_any(nil, _elems), do: nil
  defp eq_any({:text, _} = lhs, elems), do: scan_any(lhs, elems, false)

  defp scan_any({:text, a} = lhs, [{:text, b} | rest], saw_null?) do
    if a == b, do: true, else: scan_any(lhs, rest, saw_null?)
  end

  defp scan_any(lhs, [nil | rest], _saw_null?), do: scan_any(lhs, rest, true)
  defp scan_any(_lhs, [], true), do: nil
  defp scan_any(_lhs, [], false), do: false

  @doc """
  `NULLIF(a, b)` on text (`EEOP_NULLIF`, src/backend/executor/execExprInterp.c).

  Not strict: `nullif(nil, b)` is `nil`, `nullif(a, nil)` is `a`, equal values give `nil`, otherwise
  `a`. Both arguments are always evaluated, so an unsupported argument in either position wins.
  """
  @spec nullif(result, result) :: result
  def nullif({:unsupported, _} = unsupported, _b), do: unsupported
  def nullif(_a, {:unsupported, _} = unsupported), do: unsupported
  def nullif(nil, _b), do: nil
  def nullif({:text, _} = a, nil), do: a
  def nullif({:text, x} = a, {:text, y}), do: if(x == y, do: nil, else: a)

  @doc """
  `COALESCE(...)` over already-evaluated arguments (`T_CoalesceExpr`, src/backend/executor/execExpr.c).

  If any argument is unsupported, the first unsupported one is the result, wherever it is.
  Otherwise the first non-NULL argument is, and all NULL gives `nil`.

  The executor stops at the first non-NULL argument, but Postgres folds constant arguments while
  planning (and literal casts like `'x'::uuid` while parsing), before that happens. So an argument
  that is never reached at run time can still raise: `COALESCE(realtime.topic(), ((1 / 0))::text)
  = 'x'::text` fails with `division by zero`, in a plain `SELECT` as well as in `EXPLAIN`.
  """
  @spec coalesce([result]) :: result
  def coalesce(args) when is_list(args) do
    Enum.find(args, &match?({:unsupported, _}, &1)) || Enum.find(args, &(not is_nil(&1)))
  end

  @doc """
  `current_setting(name, true)` (`show_config_by_name_missing_ok`, src/backend/utils/misc/guc_funcs.c).

  `settings` maps lowercase GUC names to the string Realtime passed to `set_config`, or `nil` for
  `set_config(name, NULL)`. That is a RESET, after which Postgres returns `''` for a custom
  setting, never NULL (`ShowGUCOption`, src/backend/utils/misc/guc.c).

  The lookup folds ASCII case like `guc_name_compare`. A name missing from `settings` is
  unsupported: in Postgres it would be NULL only if nothing ever set it in the session, which this
  library can't know.
  """
  @spec current_setting(%{optional(binary()) => binary() | nil}, binary() | nil | {:unsupported, term()}) ::
          result
  def current_setting(_settings, {:unsupported, _} = unsupported), do: unsupported
  def current_setting(_settings, nil), do: nil

  def current_setting(settings, name) when is_map(settings) and is_binary(name) do
    case Map.fetch(settings, ascii_downcase(name)) do
      {:ok, nil} -> {:text, ""}
      {:ok, value} when is_binary(value) -> {:text, value}
      :error -> {:unsupported, {:unknown_setting, name}}
    end
  end

  ## Null tests

  @doc """
  `x IS NULL` (`EEOP_NULLTEST_ISNULL`, src/backend/executor/execExprInterp.c).

  Not strict: the result is never NULL, so `NULL IS NULL` is `true`. A jsonb `null` is a value,
  not SQL NULL. An unsupported argument is returned unchanged, since we don't know if it is NULL.
  """
  @spec is_null(result) :: result
  def is_null({:unsupported, _} = unsupported), do: unsupported
  def is_null(a), do: is_nil(a)

  @doc "`x IS NOT NULL` (`EEOP_NULLTEST_ISNOTNULL`). Not strict, see `is_null/1`."
  @spec is_not_null(result) :: result
  def is_not_null({:unsupported, _} = unsupported), do: unsupported
  def is_not_null(a), do: not is_nil(a)

  ## Boolean

  @doc """
  `NOT boolean` (`EEOP_BOOL_NOT_STEP`, src/backend/executor/execExprInterp.c). `NOT NULL` is NULL.
  """
  @spec bool_not(result) :: result
  def bool_not(a), do: strict1(a, fn b when is_boolean(b) -> not b end)

  @doc """
  `text::boolean` (`boolin` and `parse_bool_with_len`, src/backend/utils/adt/bool.c). Strict.

  Leading and trailing C-locale whitespace is skipped. The rest, compared case-insensitively, must
  be a non-empty prefix of `true`, `false`, `yes` or `no`, or exactly `on`, `off`, `of`, `1` or `0`.
  The `o` family is special because a lone `o` is ambiguous: `parse_bool_with_len` compares at
  least two bytes, so `of` is accepted as a prefix of `off`.

  Input with a byte above 127 is unsupported. Postgres whitespace trimming uses libc `isspace` and
  its case folding uses libc `isupper`/`tolower` for such bytes, which depend on the locale.
  """
  @spec bool_in(result) :: result
  def bool_in(a), do: strict1(a, fn {:text, s} -> parse_bool(s) end)

  defp parse_bool(s) do
    if ascii?(s) do
      s |> trim_space() |> ascii_downcase() |> bool_word()
    else
      {:unsupported, :bool_in_non_ascii}
    end
  end

  defp bool_word(<<?t, _::binary>> = w), do: prefix_bool(w, "true", true)
  defp bool_word(<<?f, _::binary>> = w), do: prefix_bool(w, "false", false)
  defp bool_word(<<?y, _::binary>> = w), do: prefix_bool(w, "yes", true)
  defp bool_word(<<?n, _::binary>> = w), do: prefix_bool(w, "no", false)
  defp bool_word("on"), do: true
  defp bool_word(w) when w in ["of", "off"], do: false
  defp bool_word("1"), do: true
  defp bool_word("0"), do: false
  defp bool_word(_), do: invalid_input("boolean")

  defp prefix_bool(w, word, result) do
    if byte_size(w) <= byte_size(word) and binary_part(word, 0, byte_size(w)) == w do
      result
    else
      invalid_input("boolean")
    end
  end

  # isspace() in the C locale: space, \t, \n, \v, \f, \r.
  defp trim_space(s), do: s |> trim_leading_space() |> trim_trailing_space()

  defp trim_leading_space(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\v, ?\f, ?\r], do: trim_leading_space(rest)
  defp trim_leading_space(s), do: s

  defp trim_trailing_space(s) do
    size = byte_size(s)

    if size > 0 and :binary.last(s) in [?\s, ?\t, ?\n, ?\v, ?\f, ?\r] do
      trim_trailing_space(binary_part(s, 0, size - 1))
    else
      s
    end
  end

  ## UUID

  @doc "`uuid = uuid` (`uuid_eq`, src/backend/utils/adt/uuid.c). Strict."
  @spec uuid_eq(result, result) :: result
  def uuid_eq(a, b), do: strict2(a, b, fn {:uuid, x}, {:uuid, y} -> x == y end)

  @doc "`uuid <> uuid` (`uuid_ne`, src/backend/utils/adt/uuid.c). Strict."
  @spec uuid_ne(result, result) :: result
  def uuid_ne(a, b), do: strict2(a, b, fn {:uuid, x}, {:uuid, y} -> x != y end)

  @doc """
  `text::uuid` (`uuid_in` and `string_to_uuid`, src/backend/utils/adt/uuid.c). Strict.

  Accepts an optional leading `{` (which then requires a trailing `}`), exactly 32 hex digits in
  either case, and one optional `-` after any group of 4 hex digits except the last. Anything else
  raises `invalid_text_representation`: no whitespace, no doubled hyphens.
  """
  @spec uuid_in(result) :: result
  def uuid_in(a), do: strict1(a, fn {:text, s} -> parse_uuid(s) end)

  defp parse_uuid(<<"{", rest::binary>>) do
    case read_uuid(rest, 0, <<>>) do
      {:ok, uuid, "}"} -> {:uuid, uuid}
      _ -> invalid_input("uuid")
    end
  end

  defp parse_uuid(s) do
    case read_uuid(s, 0, <<>>) do
      {:ok, uuid, ""} -> {:uuid, uuid}
      _ -> invalid_input("uuid")
    end
  end

  # Reads 16 bytes as pairs of hex digits. As in string_to_uuid, a hyphen is skipped only right
  # after a complete group of 4 hex digits (odd byte index) and never after the last group.
  defp read_uuid(rest, 16, acc), do: {:ok, acc, rest}

  defp read_uuid(<<h1, h2, rest::binary>>, i, acc) when is_hex(h1) and is_hex(h2) do
    rest =
      case rest do
        <<?-, after_hyphen::binary>> when rem(i, 2) == 1 and i < 15 -> after_hyphen
        _ -> rest
      end

    read_uuid(rest, i + 1, <<acc::binary, hex_value(h1)::4, hex_value(h2)::4>>)
  end

  defp read_uuid(_rest, _i, _acc), do: :error

  defp hex_value(c) when c in ?0..?9, do: c - ?0
  defp hex_value(c) when c in ?a..?f, do: c - ?a + 10
  defp hex_value(c) when c in ?A..?F, do: c - ?A + 10

  @doc "`uuid::text` (`uuid_out`, src/backend/utils/adt/uuid.c): lowercase 8-4-4-4-12. Strict."
  @spec uuid_out(result) :: result
  def uuid_out(a), do: strict1(a, fn {:uuid, _} = uuid -> {:text, format_uuid(uuid)} end)

  defp format_uuid(
         {:uuid, <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2), e::binary-size(6)>>}
       ) do
    [a, b, c, d, e] |> Enum.map_join("-", &Base.encode16(&1, case: :lower))
  end

  ## Regular expressions

  @doc """
  `text ~ text` and `text ~* text` (`textregexeq` and `texticregexeq`, src/backend/utils/adt/regexp.c).
  Strict, for literal patterns only.

  A pattern containing any advanced-regex metacharacter (`| * + ? ( ) . ^ $ \\ [ {`) is
  `{:unsupported, :regex_not_literal}`. A literal pattern is an unanchored substring match, and an
  empty pattern matches everything.

  This check comes before the NULL check, so a NULL subject with a non-literal pattern is
  unsupported rather than NULL. The function is strict, but the planner's selectivity estimation
  compiles constant patterns even when the subject is NULL, which raises for an invalid regex.

  `~*` is only decided when subject and pattern are all ASCII: Postgres then folds ASCII letters
  with ASCII rules (`pg_wc_tolower`, src/backend/regex/regc_pg_locale.c). Any byte above 127 is
  `{:unsupported, :regex_non_ascii}` because folding of other characters depends on the collation
  provider and locale (`'i' ~* 'İ'` and `'I' ~* 'ı'` are both true under an ICU default collation).
  """
  @spec regex_match(result, result, :case_sensitive | :case_insensitive) :: result
  def regex_match({:unsupported, _} = unsupported, _pattern, _mode), do: unsupported
  def regex_match(_subject, {:unsupported, _} = unsupported, _mode), do: unsupported

  def regex_match(subject, pattern, mode) when mode in [:case_sensitive, :case_insensitive] do
    cond do
      not literal_pattern?(pattern) -> {:unsupported, :regex_not_literal}
      is_nil(subject) or is_nil(pattern) -> nil
      true -> literal_match(subject, pattern, mode)
    end
  end

  defp literal_pattern?(nil), do: true
  defp literal_pattern?({:text, p}), do: not String.contains?(p, @regex_meta)

  defp literal_match(_subject, {:text, ""}, _mode), do: true
  defp literal_match({:text, subject}, {:text, pattern}, :case_sensitive), do: contains?(subject, pattern)

  defp literal_match({:text, subject}, {:text, pattern}, :case_insensitive) do
    if ascii?(subject) and ascii?(pattern) do
      contains?(ascii_downcase(subject), ascii_downcase(pattern))
    else
      {:unsupported, :regex_non_ascii}
    end
  end

  defp contains?(subject, pattern), do: :binary.match(subject, pattern) != :nomatch

  ## Helpers

  # Strict functions: the first unsupported argument wins, then any NULL gives NULL.
  defp strict1({:unsupported, _} = unsupported, _fun), do: unsupported
  defp strict1(nil, _fun), do: nil
  defp strict1(a, fun), do: fun.(a)

  defp strict2({:unsupported, _} = unsupported, _b, _fun), do: unsupported
  defp strict2(_a, {:unsupported, _} = unsupported, _fun), do: unsupported
  defp strict2(nil, _b, _fun), do: nil
  defp strict2(_a, nil, _fun), do: nil
  defp strict2(a, b, fun), do: fun.(a, b)

  defp invalid_input(type) do
    {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type #{type}"}}
  end

  defp ascii?(<<>>), do: true
  defp ascii?(<<c, rest::binary>>) when c < 128, do: ascii?(rest)
  defp ascii?(_), do: false

  # Only A-Z are folded, like guc_name_compare and pg_ascii_tolower.
  defp ascii_downcase(bin), do: for(<<c <- bin>>, into: <<>>, do: <<ascii_down(c)>>)

  defp ascii_down(c) when c in ?A..?Z, do: c + (?a - ?A)
  defp ascii_down(c), do: c
end
