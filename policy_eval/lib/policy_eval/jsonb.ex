defmodule PolicyEval.Jsonb do
  @moduledoc """
  The jsonb primitives: `text::jsonb`, `jsonb -> text`, `jsonb -> integer`, `jsonb ->> text` and
  `jsonb ->> integer`.

  A jsonb value is `{:jsonb, term}` where `term` is a decoded JSON value:

    * objects are maps with binary keys
    * arrays are lists
    * strings are binaries
    * `true` and `false` are booleans
    * JSON null is `:null`, which is not SQL NULL (`nil`)
    * numbers are `{:number, raw_token}`; jsonb re-normalises numbers (`1e2` becomes `100`) and we
      don't model that, so numbers are only ever carried around, never interpreted

  No primitive here prints a jsonb value. `->` passes on a part of the decoded tree, so a number,
  an object or an array keeps its form until a primitive needs its text. The only one that does is
  `->>`, and it is unsupported for those three.

  Results follow `PolicyEval.Value`: a value, `nil`, or `{:unsupported, reason}`.
  """

  alias PolicyEval.Value

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
  def object_field_text(jsonb, key), do: as_text(object_field(jsonb, key))

  @doc """
  `jsonb ->> integer` (`jsonb_array_element_text`, src/backend/utils/adt/jsonfuncs.c). Strict.

  The element that `array_element/2` finds, as text by the rules of `object_field_text/2`. A JSON
  null gives `nil`, and so does an index outside the array or an object root.
  """
  @spec array_element_text(Value.result(), Value.result()) :: Value.result()
  def array_element_text(jsonb, index), do: as_text(array_element(jsonb, index))

  @doc """
  `jsonb -> text` (`jsonb_object_field`, src/backend/utils/adt/jsonfuncs.c). Strict.

  The value of the field as jsonb, whatever its type. A JSON null is the jsonb value `null`, which
  is not SQL NULL. A root that isn't an object and a missing key give `nil`.
  """
  @spec object_field(Value.result(), Value.result()) :: Value.result()
  def object_field({:unsupported, _} = unsupported, _key), do: unsupported
  def object_field(_jsonb, {:unsupported, _} = unsupported), do: unsupported
  def object_field(nil, _key), do: nil
  def object_field(_jsonb, nil), do: nil

  def object_field({:jsonb, root}, {:text, key}) when is_map(root) do
    case Map.fetch(root, key) do
      {:ok, value} -> {:jsonb, value}
      :error -> nil
    end
  end

  def object_field({:jsonb, _root}, {:text, _key}), do: nil

  @doc """
  `jsonb -> integer` (`jsonb_array_element`, src/backend/utils/adt/jsonfuncs.c). Strict.

  The element at `index` as jsonb, counted from 0. A negative index counts from the end, so `-1` is
  the last element. An index outside the array gives `nil`, and so does an object root.

  A scalar root is an array of one element, because jsonb stores a scalar that way and the
  function only checks for an array: `'"a"'::jsonb -> 0` and `'"a"'::jsonb -> -1` are both `"a"`.
  """
  @spec array_element(Value.result(), Value.result()) :: Value.result()
  def array_element({:unsupported, _} = unsupported, _index), do: unsupported
  def array_element(_jsonb, {:unsupported, _} = unsupported), do: unsupported
  def array_element(nil, _index), do: nil
  def array_element(_jsonb, nil), do: nil
  def array_element({:jsonb, root}, {:int4, _index}) when is_map(root), do: nil
  def array_element({:jsonb, root}, {:int4, index}) when is_list(root), do: element(root, index)
  def array_element({:jsonb, scalar}, {:int4, index}), do: element([scalar], index)

  # Enum.at/2 counts a negative index from the end and gives nil outside the list, as
  # jsonb_array_element does. nil can't be an element, because JSON null is :null.
  defp element(elements, index) do
    case Enum.at(elements, index) do
      nil -> nil
      value -> {:jsonb, value}
    end
  end

  # JsonbValueAsText for the value that `->` found. A JSON null is SQL NULL here.
  defp as_text({:jsonb, :null}), do: nil
  defp as_text({:jsonb, string}) when is_binary(string), do: {:text, string}
  defp as_text({:jsonb, bool}) when is_boolean(bool), do: {:text, Atom.to_string(bool)}
  defp as_text({:jsonb, {:number, _}}), do: {:unsupported, :jsonb_number_text}

  defp as_text({:jsonb, container}) when is_map(container) or is_list(container),
    do: {:unsupported, :jsonb_container_text}

  defp as_text(nil_or_unsupported), do: nil_or_unsupported

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
    :throw, {:policy_eval_jsonb, result} -> result
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

  defp bail(result), do: throw({:policy_eval_jsonb, result})

  # Postgres says "type json" here even for jsonb.
  defp invalid_json do
    {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type json"}}
  end
end
