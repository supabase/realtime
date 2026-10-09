defmodule SqlLogex.Jsonb do
  @moduledoc """
  The jsonb primitives: `text::jsonb` and `jsonb ->> text`.

  A jsonb value is `{:jsonb, term}` where `term` is a decoded JSON value:

    * objects are maps with binary keys
    * arrays are lists
    * strings are binaries
    * `true` and `false` are booleans
    * JSON null is `:null`, which is not SQL NULL (`nil`)
    * numbers are `{:number, raw_token}`; jsonb re-normalises numbers (`1e2` becomes `100`) and we
      don't model that, so numbers are only ever carried around, never interpreted

  Results follow `SqlLogex.Value`: a value, `nil`, or `{:unsupported, reason}`.
  """

  alias SqlLogex.Value

  @type json :: :null | boolean() | binary() | {:number, binary()} | [json] | %{optional(binary()) => json}

  # Postgres accepts far more: the recursive parser is only limited by max_stack_depth (measured on
  # 17.11 with the default 2MB: 6401 levels parse, 20000 raise "stack depth limit exceeded"). A
  # policy has no use for deep documents, so anything deeper is simply handed to the database.
  @max_depth 100

  # numeric_in raises "value overflows numeric format" for huge exponents or digit counts
  # (src/backend/utils/adt/numeric.c). Staying far below the limits (131072 digits before the
  # decimal point, 16383 after) means no number here can raise, so no check has to be modelled.
  @max_number_bytes 1000
  @max_exponent 1000

  @doc """
  `text::jsonb` (`jsonb_in` and `jsonb_from_cstring`, src/backend/utils/adt/jsonb.c, with the lexer
  in src/common/jsonapi.c). Strict.

  Mirrors Postgres where Elixir's `JSON` decoder differs by default:

    * on duplicate object keys the last value wins (`uniqueifyJsonbObject`)
    * a string, or key, containing the escape `\\u0000` raises `untranslatable_character`
    * invalid JSON raises `invalid_text_representation`: the empty string, unpaired surrogate
      escapes, a raw control character in a string, trailing garbage, and so on. Both parsers
      implement RFC 8259 and agree on whitespace (space, tab, LF, CR), number syntax (no leading
      zeros, `+`, `.5` or `1.`) and escapes.

  Cases where the two might differ are `{:unsupported, reason}` instead of a guess:

    * `:invalid_utf8`: the input isn't valid UTF-8, which a Postgres text value never is
    * `:jsonb_too_deeply_nested`: more than #{@max_depth} levels of nesting
    * `:jsonb_number_range`: a number token longer than #{@max_number_bytes} bytes or with an
      exponent beyond #{@max_exponent}, where numeric_in may raise
    * `:jsonb_number_token`: `JSON.decode/3` rewrites a number such as `1e5` as `1.0e5` before
      handing it over, so the raw token can't be trusted. The check is deliberately broader than
      needed and also catches a genuine `1.0e5`.

  One number is not kept verbatim: `-0` comes out as `{:number, "0"}`, because the decoder hands
  over `0`. That is harmless as numeric has no negative zero, so jsonb prints both as `0`.
  """
  @spec parse(Value.result()) :: Value.result()
  def parse({:unsupported, _} = unsupported), do: unsupported
  def parse(nil), do: nil

  def parse({:text, input}) when is_binary(input) do
    if String.valid?(input), do: decode(input), else: {:unsupported, :invalid_utf8}
  end

  @doc """
  `jsonb ->> text` (`jsonb_object_field_text` and `JsonbValueAsText`, src/backend/utils/adt/jsonfuncs.c).
  Strict.

  A root that isn't an object, a missing key and a JSON null all give `nil`. Strings give their
  unescaped text and booleans `true` or `false`.

  A number would be rendered by `numeric_out` from the normalised value, which we don't model, and
  an object or array by `JsonbToCString`, so those are `{:unsupported, :jsonb_number_text}` and
  `{:unsupported, :jsonb_container_text}`.
  """
  @spec object_field_text(Value.result(), Value.result()) :: Value.result()
  def object_field_text({:unsupported, _} = unsupported, _key), do: unsupported
  def object_field_text(_jsonb, {:unsupported, _} = unsupported), do: unsupported
  def object_field_text(nil, _key), do: nil
  def object_field_text(_jsonb, nil), do: nil

  def object_field_text({:jsonb, root}, {:text, key}) when is_map(root) do
    case Map.fetch(root, key) do
      :error -> nil
      {:ok, :null} -> nil
      {:ok, string} when is_binary(string) -> {:text, string}
      {:ok, bool} when is_boolean(bool) -> {:text, Atom.to_string(bool)}
      {:ok, {:number, _}} -> {:unsupported, :jsonb_number_text}
      {:ok, container} when is_map(container) or is_list(container) -> {:unsupported, :jsonb_container_text}
    end
  end

  def object_field_text({:jsonb, _root}, {:text, _key}), do: nil

  ## Decoding

  # The accumulator is {depth, items} for the innermost open container, so the callbacks can
  # enforce the depth limit. A callback that can't continue throws the final result.
  #
  # The `float` callback can't throw: the decoder runs it inside `try ... catch _:_` and reports any
  # exception as a plain syntax error, which here would wrongly mean "Postgres raises". So it only
  # tags the token, and `checked/1` looks at it where the value is stored, which is in a container
  # push callback or, for a top-level number, right after decoding.
  defp decode(input) do
    case JSON.decode(input, {0, nil}, decoders()) do
      {value, _acc, ""} -> {:jsonb, checked(value)}
      {_value, _acc, _trailing_garbage} -> invalid_json()
      {:error, _reason} -> invalid_json()
    end
  catch
    :throw, {:sql_logex_jsonb, result} -> result
  end

  defp decoders do
    [
      null: :null,
      string: &string/1,
      integer: &integer/1,
      float: &{:float_token, &1},
      array_start: fn {depth, _} -> {nest(depth), []} end,
      array_push: fn element, {depth, items} -> {depth, [checked(element) | items]} end,
      array_finish: fn {_depth, items}, outer -> {Enum.reverse(items), outer} end,
      object_start: fn {depth, _} -> {nest(depth), %{}} end,
      # Map.put/3 makes the last of several equal keys win, as in jsonb.
      object_push: fn key, value, {depth, map} -> {depth, Map.put(map, key, checked(value))} end,
      object_finish: fn {_depth, map}, outer -> {map, outer} end
    ]
  end

  defp nest(depth) when depth >= @max_depth, do: bail({:unsupported, :jsonb_too_deeply_nested})
  defp nest(depth), do: depth + 1

  # Called for object keys too. The decoder has already rejected raw control characters, so a NUL
  # byte can only come from the escape \u0000.
  defp string(s) do
    case :binary.match(s, <<0>>) do
      :nomatch -> s
      _ -> bail({:unsupported, {:raises, :untranslatable_character, "unsupported Unicode escape sequence"}})
    end
  end

  defp integer(token) when byte_size(token) <= @max_number_bytes, do: {:number, token}
  defp integer(_token), do: bail({:unsupported, :jsonb_number_range})

  defp checked({:float_token, token}) do
    cond do
      String.contains?(token, ".0e") -> bail({:unsupported, :jsonb_number_token})
      byte_size(token) > @max_number_bytes or exponent_too_large?(token) -> bail({:unsupported, :jsonb_number_range})
      true -> {:number, token}
    end
  end

  defp checked(value), do: value

  defp exponent_too_large?(token) do
    case :binary.split(token, ["e", "E"]) do
      [_mantissa, exponent] -> abs(String.to_integer(exponent)) > @max_exponent
      [_mantissa] -> false
    end
  end

  defp bail(result), do: throw({:sql_logex_jsonb, result})

  # Postgres says "type json" here even for jsonb.
  defp invalid_json do
    {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type json"}}
  end
end
