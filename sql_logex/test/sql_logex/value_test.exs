defmodule SqlLogex.ValueTest do
  use ExUnit.Case, async: true

  alias SqlLogex.Value

  @uuid <<0xA0, 0xEE, 0xBC, 0x99, 0x9C, 0x0B, 0x4E, 0xF8, 0xBB, 0x6D, 0x6B, 0xB9, 0xBD, 0x38, 0x0A, 0x11>>
  @uuid_text "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @uuid_hex "a0eebc999c0b4ef8bb6d6bb9bd380a11"
  @other_uuid <<1::128>>

  # Spelled as bytes so the sources don't hide invisible or look-alike characters.
  @nbsp <<0xC2, 0xA0>>
  @nel <<0xC2, 0x85>>
  @em_space <<0xE2, 0x80, 0x83>>
  @fullwidth_a <<0xEF, 0xBD, 0x81>>
  @fullwidth_true <<0xEF, 0xBD, 0x94, 0xEF, 0xBD, 0x92, 0xEF, 0xBD, 0x95, 0xEF, 0xBD, 0x85>>
  @kelvin <<0xE2, 0x84, 0xAA>>

  @boom {:unsupported, :boom}
  @bang {:unsupported, :bang}

  @invalid_uuid {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type uuid"}}
  @invalid_bool {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type boolean"}}

  defp t(s), do: {:text, s}
  defp u(bin \\ @uuid), do: {:uuid, bin}

  # Inserts a hyphen after each of the given counts of hex digits in the 32 digit string.
  defp hyphenate(hex, positions) do
    hex
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.map_join(fn {digit, n} -> if n in positions, do: digit <> "-", else: digit end)
  end

  describe "NULL and unsupported propagation in strict functions" do
    # {label, function, valid arguments, indexes of the arguments that are values (the rest are options)}
    @strict [
      {"text_eq", :text_eq, [{:text, "a"}, {:text, "a"}], [0, 1]},
      {"text_ne", :text_ne, [{:text, "a"}, {:text, "b"}], [0, 1]},
      {"uuid_eq", :uuid_eq, [{:uuid, @uuid}, {:uuid, @uuid}], [0, 1]},
      {"uuid_ne", :uuid_ne, [{:uuid, @uuid}, {:uuid, @other_uuid}], [0, 1]},
      {"textcat", :textcat, [{:text, "a"}, {:text, "b"}], [0, 1]},
      {"textanycat", :textanycat, [{:text, "a"}, {:uuid, @uuid}], [0, 1]},
      {"uuid_in", :uuid_in, [{:text, @uuid_text}], [0]},
      {"uuid_out", :uuid_out, [{:uuid, @uuid}], [0]},
      {"bool_in", :bool_in, [{:text, "true"}], [0]},
      {"bool_not", :bool_not, [true], [0]},
      {"regex_match (~)", :regex_match, [{:text, "abc"}, {:text, "b"}, :case_sensitive], [0, 1]},
      {"regex_match (~*)", :regex_match, [{:text, "abc"}, {:text, "B"}, :case_insensitive], [0, 1]}
    ]

    for {label, fun, args, positions} <- @strict, position <- positions do
      test "#{label} returns nil for a NULL argument at #{position}" do
        args = unquote(Macro.escape(args))
        assert apply(Value, unquote(fun), List.replace_at(args, unquote(position), nil)) == nil
      end

      test "#{label} returns an unsupported argument at #{position} unchanged" do
        args = unquote(Macro.escape(args))
        assert apply(Value, unquote(fun), List.replace_at(args, unquote(position), @boom)) == @boom
      end
    end

    for {label, fun, args, [_, _] = positions} <- @strict do
      test "#{label} lets an unsupported argument win over NULL, and the first one win" do
        args = unquote(Macro.escape(args))
        [first, second] = unquote(positions)

        assert apply(Value, unquote(fun), args |> List.replace_at(first, nil) |> List.replace_at(second, @boom)) ==
                 @boom

        assert apply(Value, unquote(fun), args |> List.replace_at(first, @boom) |> List.replace_at(second, nil)) ==
                 @boom

        assert apply(Value, unquote(fun), args |> List.replace_at(first, @boom) |> List.replace_at(second, @bang)) ==
                 @boom

        assert apply(Value, unquote(fun), args |> List.replace_at(first, nil) |> List.replace_at(second, nil)) == nil
      end
    end
  end

  describe "text_eq/2 and text_ne/2" do
    for {a, b, eq} <- [
          {"a", "a", true},
          {"a", "b", false},
          {"a", "A", false},
          {"", "", true},
          {"", "a", false},
          {"a", "a ", false},
          {"café", "café", true},
          # precomposed é vs e followed by U+0301 (combining acute accent): different bytes, so different
          {"café", "café", false}
        ] do
      test "compares #{inspect(a)} with #{inspect(b)} by bytes" do
        assert Value.text_eq(t(unquote(a)), t(unquote(b))) == unquote(eq)
        assert Value.text_ne(t(unquote(a)), t(unquote(b))) == not unquote(eq)
      end
    end
  end

  describe "uuid_eq/2 and uuid_ne/2" do
    test "compare the 16 bytes" do
      assert Value.uuid_eq(u(), u()) == true
      assert Value.uuid_ne(u(), u()) == false
      assert Value.uuid_eq(u(), u(@other_uuid)) == false
      assert Value.uuid_ne(u(), u(@other_uuid)) == true
    end
  end

  describe "textcat/2" do
    test "concatenates bytes" do
      assert Value.textcat(t("ab"), t("cd")) == t("abcd")
      assert Value.textcat(t(""), t("cd")) == t("cd")
      assert Value.textcat(t("ab"), t("")) == t("ab")
      assert Value.textcat(t(""), t("")) == t("")
    end
  end

  describe "textanycat/2" do
    test "renders the uuid with uuid_out: lowercase 8-4-4-4-12" do
      assert Value.textanycat(t("user:"), u()) == t("user:" <> @uuid_text)
      assert Value.textanycat(t(""), u()) == t(@uuid_text)
      assert Value.textanycat(t("x"), u(<<0::128>>)) == t("x00000000-0000-0000-0000-000000000000")
    end

    test "gives the same text for any spelling of the uuid" do
      {:uuid, _} = parsed = Value.uuid_in(t("{A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11}"))
      assert Value.textanycat(t("user:"), parsed) == t("user:" <> @uuid_text)
    end

    test "only implements uuid for the right-hand side" do
      assert Value.textanycat(t("a"), t("b")) == {:unsupported, :textanycat_non_uuid}
      assert Value.textanycat(t("a"), true) == {:unsupported, :textanycat_non_uuid}
      assert Value.textanycat(t("a"), {:jsonb, :null}) == {:unsupported, :textanycat_non_uuid}
    end
  end

  describe "uuid_in/1 accepted forms" do
    test "the canonical form in either case, and mixed" do
      assert Value.uuid_in(t(@uuid_text)) == u()
      assert Value.uuid_in(t(String.upcase(@uuid_text))) == u()
      assert Value.uuid_in(t("A0eeBC99-9c0B-4eF8-bB6d-6bB9bD380a11")) == u()
    end

    test "an optional hyphen after every group of 4 digits but the last, in every combination" do
      for mask <- 0..127 do
        positions = for bit <- 0..6, Bitwise.band(mask, Bitwise.bsl(1, bit)) != 0, do: (bit + 1) * 4
        text = hyphenate(@uuid_hex, positions)

        assert Value.uuid_in(t(text)) == u(), "uuid_in(#{inspect(text)})"
        assert Value.uuid_in(t("{" <> text <> "}")) == u(), "uuid_in(#{inspect("{" <> text <> "}")})"
      end
    end

    test "braces around the 32 digits" do
      assert Value.uuid_in(t("{" <> @uuid_text <> "}")) == u()
      assert Value.uuid_in(t("{" <> @uuid_hex <> "}")) == u()
    end

    test "hyphens in the non-canonical places Postgres allows" do
      assert Value.uuid_in(t("a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11")) == u()
      assert Value.uuid_in(t("a0eebc99-9c0b4ef8-bb6d6bb9-bd380a11")) == u()
    end

    test "the nil and zero uuids" do
      assert Value.uuid_in(t("00000000-0000-0000-0000-000000000000")) == u(<<0::128>>)
      assert Value.uuid_in(t("FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")) == u(<<-1::128>>)
    end
  end

  describe "uuid_in/1 rejected forms" do
    for {name, input} <- [
          {"empty", ""},
          {"only braces", "{}"},
          {"only an open brace", "{"},
          {"only a close brace", "}"},
          {"only a hyphen", "-"},
          {"leading space", " " <> @uuid_text},
          {"trailing space", @uuid_text <> " "},
          {"inner space", "a0eebc99 9c0b-4ef8-bb6d-6bb9bd380a11"},
          {"trailing newline", @uuid_text <> "\n"},
          {"leading tab", "\t" <> @uuid_text},
          {"space inside braces", "{ " <> @uuid_text <> "}"},
          {"space after closing brace", "{" <> @uuid_text <> "} "},
          {"double hyphen", "a0eebc99--9c0b-4ef8-bb6d-6bb9bd380a11"},
          {"double hyphen at another group", "a0eebc99-9c0b-4ef8--bb6d-6bb9bd380a11"},
          {"leading hyphen", "-" <> @uuid_text},
          {"trailing hyphen", @uuid_text <> "-"},
          {"trailing hyphen without hyphens elsewhere", @uuid_hex <> "-"},
          {"31 digits", String.slice(@uuid_hex, 0, 31)},
          {"33 digits", @uuid_hex <> "0"},
          {"31 digits in canonical form", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a1"},
          {"33 digits in canonical form", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a110"},
          {"open brace only", "{" <> @uuid_text},
          {"close brace only", @uuid_text <> "}"},
          {"open brace only, no hyphens", "{" <> @uuid_hex},
          {"double open brace", "{{" <> @uuid_text <> "}"},
          {"double close brace", "{" <> @uuid_text <> "}}"},
          {"other brackets", "(" <> @uuid_text <> ")"},
          {"a non-hex digit", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a1g"},
          {"a 0x prefix", "0x" <> String.slice(@uuid_hex, 2, 30)},
          {"urn prefix", "urn:uuid:" <> @uuid_text},
          {"a fullwidth digit", @fullwidth_a <> String.slice(@uuid_hex, 1, 31)},
          {"a non-ASCII letter", String.slice(@uuid_hex, 0, 31) <> "é"},
          {"an escaped uuid", "\\" <> @uuid_hex}
        ] do
      test "raises for #{name}" do
        assert Value.uuid_in(t(unquote(input))) == @invalid_uuid
      end
    end

    test "a hyphen is only accepted after a complete group of 4 digits" do
      for k <- 0..32 do
        text = String.slice(@uuid_hex, 0, k) <> "-" <> String.slice(@uuid_hex, k, 32)

        expected = if k in 4..28//4, do: u(), else: @invalid_uuid
        assert Value.uuid_in(t(text)) == expected, "hyphen after #{k} digits: #{inspect(text)}"
      end
    end

    test "a doubled hyphen is rejected at every allowed position" do
      for k <- 4..28//4 do
        text = hyphenate(@uuid_hex, [k]) |> String.replace("-", "--")
        assert Value.uuid_in(t(text)) == @invalid_uuid, inspect(text)
      end
    end
  end

  describe "uuid_out/1" do
    test "prints lowercase 8-4-4-4-12" do
      assert Value.uuid_out(u()) == t(@uuid_text)
      assert Value.uuid_out(u(<<0::128>>)) == t("00000000-0000-0000-0000-000000000000")
      assert Value.uuid_out(u(<<-1::128>>)) == t("ffffffff-ffff-ffff-ffff-ffffffffffff")
    end

    test "round trips every accepted spelling to the canonical form" do
      for input <- [
            "{A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11}",
            "A0EEBC999C0B4EF8BB6D6BB9BD380A11",
            "a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11"
          ] do
        assert input |> t() |> Value.uuid_in() |> Value.uuid_out() == t(@uuid_text)
      end
    end
  end

  describe "bool_in/1" do
    # Every prefix of these words is accepted, whatever the case.
    for {word, result} <- [{"true", true}, {"false", false}, {"yes", true}, {"no", false}],
        len <- 1..byte_size(word) do
      prefix = binary_part(word, 0, len)

      alternating =
        prefix
        |> String.graphemes()
        |> Enum.with_index()
        |> Enum.map_join(fn {c, i} -> if rem(i, 2) == 0, do: String.upcase(c), else: c end)

      for variant <- Enum.uniq([prefix, String.upcase(prefix), String.capitalize(prefix), alternating]) do
        test "accepts #{inspect(variant)} as #{result}" do
          assert Value.bool_in(t(unquote(variant))) == unquote(result)
        end
      end

      test "rejects #{inspect(prefix)} plus an extra character" do
        assert Value.bool_in(t(unquote(prefix <> "x"))) == @invalid_bool
      end
    end

    for {input, result} <- [
          {"on", true},
          {"ON", true},
          {"On", true},
          {"off", false},
          {"OFF", false},
          {"Off", false},
          # parse_bool_with_len compares at least two bytes, so "of" is a prefix of "off"
          {"of", false},
          {"OF", false},
          {"oF", false},
          {"1", true},
          {"0", false}
        ] do
      test "accepts #{inspect(input)} as #{result}" do
        assert Value.bool_in(t(unquote(input))) == unquote(result)
      end
    end

    for input <- [
          "",
          " ",
          "o",
          "O",
          "oo",
          "onn",
          "on x",
          "offf",
          "ono",
          "01",
          "10",
          "11",
          "00",
          "2",
          "-1",
          "+1",
          "1.0",
          "tf",
          "ty",
          "yn",
          "nf",
          "t r",
          "tr ue",
          "o n",
          "o ff",
          "truee",
          "yess",
          "nope",
          "falsee",
          "x",
          "null",
          "t,f",
          "'true'",
          "\"true\""
        ] do
      test "rejects #{inspect(input)}" do
        assert Value.bool_in(t(unquote(input))) == @invalid_bool
      end
    end

    for ws <- [" ", "\t", "\n", "\v", "\f", "\r", " \t\r\n\v\f "] do
      test "skips #{inspect(ws)} around the value" do
        for {input, result} <- [{"true", true}, {"f", false}, {"of", false}, {"On", true}, {"1", true}, {"0", false}] do
          assert Value.bool_in(t(unquote(ws) <> input)) == result
          assert Value.bool_in(t(input <> unquote(ws))) == result
          assert Value.bool_in(t(unquote(ws) <> input <> unquote(ws))) == result
        end
      end

      test "rejects #{inspect(ws)} inside the value" do
        assert Value.bool_in(t("tr" <> unquote(ws) <> "ue")) == @invalid_bool
        assert Value.bool_in(t("1" <> unquote(ws) <> "0")) == @invalid_bool
      end
    end

    test "a value of only whitespace is invalid" do
      assert Value.bool_in(t(" \t\n\v\f\r")) == @invalid_bool
    end

    test "is unsupported for any byte above 127 because libc decides what is whitespace or a letter" do
      for input <- ["é", "t" <> @nbsp, @nbsp <> "t", "tru" <> "é", "true" <> @nel, @em_space <> "true", @fullwidth_true] do
        assert Value.bool_in(t(input)) == {:unsupported, :bool_in_non_ascii}, inspect(input)
      end
    end
  end

  describe "bool_not/1" do
    test "negates, and NOT NULL is NULL" do
      assert Value.bool_not(true) == false
      assert Value.bool_not(false) == true
      assert Value.bool_not(nil) == nil
      assert Value.bool_not(@boom) == @boom
    end
  end

  describe "is_null/1 and is_not_null/1" do
    test "are never NULL themselves: NULL IS NULL is true" do
      assert Value.is_null(nil) == true
      assert Value.is_not_null(nil) == false
    end

    test "every value is not NULL, including false, the empty string and a jsonb null" do
      for value <- [true, false, t(""), t("a"), u(), {:jsonb, :null}, {:jsonb, %{}}] do
        assert Value.is_null(value) == false, inspect(value)
        assert Value.is_not_null(value) == true, inspect(value)
      end
    end

    test "an unsupported argument is returned unchanged, so it can't be told from NULL" do
      assert Value.is_null(@boom) == @boom
      assert Value.is_not_null(@boom) == @boom
    end
  end

  describe "nullif/2" do
    test "follows NULLIF semantics for text" do
      assert Value.nullif(nil, nil) == nil
      assert Value.nullif(nil, t("a")) == nil
      assert Value.nullif(t("a"), nil) == t("a")
      assert Value.nullif(t("a"), t("a")) == nil
      assert Value.nullif(t("a"), t("b")) == t("a")
      assert Value.nullif(t(""), t("")) == nil
      assert Value.nullif(t("a"), t("A")) == t("a")
    end

    test "evaluates both arguments, so an unsupported one in either position wins" do
      assert Value.nullif(@boom, t("a")) == @boom
      assert Value.nullif(t("a"), @boom) == @boom
      assert Value.nullif(nil, @boom) == @boom
      assert Value.nullif(@boom, nil) == @boom
      assert Value.nullif(t("a"), t("a")) == nil
      assert Value.nullif(@boom, @bang) == @boom
    end
  end

  describe "coalesce/1" do
    test "returns the first non-NULL value" do
      assert Value.coalesce([nil, t("a"), t("b")]) == t("a")
      assert Value.coalesce([t("a"), nil]) == t("a")
      assert Value.coalesce([nil, nil, t("c")]) == t("c")
      assert Value.coalesce([nil, u()]) == u()
    end

    test "false is a value, not NULL" do
      assert Value.coalesce([nil, false, true]) == false
    end

    test "is NULL when every argument is NULL" do
      assert Value.coalesce([nil]) == nil
      assert Value.coalesce([nil, nil, nil]) == nil
    end

    test "returns the first unsupported argument, wherever it is" do
      assert Value.coalesce([@boom, t("a")]) == @boom
      assert Value.coalesce([nil, @boom, t("a")]) == @boom
      assert Value.coalesce([nil, @boom, @bang]) == @boom
      assert Value.coalesce([nil, nil, @boom]) == @boom
    end

    # Postgres folds a constant argument while planning, before COALESCE would stop at the first value
    test "an unsupported argument after a value still makes it unsupported" do
      assert Value.coalesce([t("a"), @boom]) == @boom
      assert Value.coalesce([nil, t("a"), @boom]) == @boom
      assert Value.coalesce([false, @boom]) == @boom
      assert Value.coalesce([t("a"), @boom, @bang]) == @boom
    end
  end

  describe "current_setting/2" do
    @settings %{
      "request.jwt.claims" => ~s({"sub":"abc"}),
      "request.jwt.claim.sub" => "",
      "request.jwt.claim.role" => nil,
      "realtime.topic" => "room:1",
      "role" => "authenticated"
    }

    test "returns the setting as text" do
      assert Value.current_setting(@settings, "realtime.topic") == t("room:1")
      assert Value.current_setting(@settings, "role") == t("authenticated")
      assert Value.current_setting(@settings, "request.jwt.claims") == t(~s({"sub":"abc"}))
    end

    test "folds ASCII case in the name, like guc_name_compare" do
      assert Value.current_setting(@settings, "REALTIME.TOPIC") == t("room:1")
      assert Value.current_setting(@settings, "Realtime.Topic") == t("room:1")
      assert Value.current_setting(@settings, "Request.JWT.Claims") == t(~s({"sub":"abc"}))
      assert Value.current_setting(@settings, "ROLE") == t("authenticated")
    end

    test "does not fold non-ASCII letters" do
      assert Value.current_setting(%{"café.x" => "v"}, "café.x") == t("v")
      assert Value.current_setting(%{"café.x" => "v"}, "CAFÉ.X") == {:unsupported, {:unknown_setting, "CAFÉ.X"}}
    end

    test "a setting reset with set_config(name, NULL) is the empty string, never NULL" do
      assert Value.current_setting(@settings, "request.jwt.claim.role") == t("")
      assert Value.current_setting(@settings, "Request.JWT.Claim.Role") == t("")
    end

    test "an empty value stays the empty string" do
      assert Value.current_setting(@settings, "request.jwt.claim.sub") == t("")
    end

    test "an unknown name is unsupported and keeps the name as given" do
      assert Value.current_setting(@settings, "app.unknown") == {:unsupported, {:unknown_setting, "app.unknown"}}
      assert Value.current_setting(@settings, "App.Unknown") == {:unsupported, {:unknown_setting, "App.Unknown"}}

      assert Value.current_setting(@settings, "realtime.topic ") ==
               {:unsupported, {:unknown_setting, "realtime.topic "}}

      assert Value.current_setting(@settings, "") == {:unsupported, {:unknown_setting, ""}}
      assert Value.current_setting(%{}, "role") == {:unsupported, {:unknown_setting, "role"}}
    end

    test "is strict in the name" do
      assert Value.current_setting(@settings, nil) == nil
      assert Value.current_setting(@settings, @boom) == @boom
    end
  end

  describe "text_eq_any/2" do
    # {lhs, elements, result}, where a bare string is a text value
    for {lhs, elems, result} <- [
          # empty array: false, even for a NULL lhs
          {"a", [], false},
          {nil, [], false},
          # NULL lhs against a non-empty array
          {nil, ["a"], nil},
          {nil, ["a", "b"], nil},
          {nil, [nil], nil},
          {nil, [nil, "a"], nil},
          # a match is true, wherever it is and whatever else is in the array
          {"a", ["a"], true},
          {"a", ["b", "a"], true},
          {"a", ["a", "b"], true},
          {"a", ["a", nil], true},
          {"a", [nil, "a"], true},
          {"a", ["b", nil, "c", "a"], true},
          {"", [""], true},
          # no match: NULL if any element is NULL, else false
          {"a", ["b"], false},
          {"a", ["b", "c"], false},
          {"a", ["A"], false},
          {"a", ["a "], false},
          {"a", [nil], nil},
          {"a", ["b", nil], nil},
          {"a", [nil, "b"], nil},
          {"a", [nil, nil], nil},
          {"", ["a"], false}
        ] do
      test "#{inspect(lhs)} = ANY (#{inspect(elems)}) is #{inspect(result)}" do
        to_value = fn
          nil -> nil
          s -> t(s)
        end

        assert Value.text_eq_any(to_value.(unquote(lhs)), Enum.map(unquote(elems), to_value)) == unquote(result)
      end
    end

    test "an unsupported lhs or element is returned" do
      assert Value.text_eq_any(@boom, [t("a")]) == @boom
      assert Value.text_eq_any(t("a"), [@boom]) == @boom
      assert Value.text_eq_any(t("a"), [t("b"), @boom]) == @boom
      assert Value.text_eq_any(nil, [@boom]) == @boom
    end

    test "all array elements are evaluated before the comparison, so an unsupported element after a match still wins" do
      assert Value.text_eq_any(t("a"), [t("a"), @boom]) == @boom
      assert Value.text_eq_any(t("a"), [t("a"), nil, @boom]) == @boom
    end

    test "the first unsupported argument wins, lhs first" do
      assert Value.text_eq_any(@boom, [@bang]) == @boom
      assert Value.text_eq_any(t("a"), [@boom, @bang]) == @boom
      assert Value.text_eq_any(@boom, []) == @boom
    end
  end

  describe "regex_match/3 with non-literal patterns" do
    for meta <- ["|", "*", "+", "?", "(", ")", ".", "^", "$", "\\", "[", "{"] do
      test "#{inspect(meta)} makes the pattern unsupported" do
        for pattern <- [unquote(meta), "a" <> unquote(meta), unquote(meta) <> "a", "a" <> unquote(meta) <> "b"],
            mode <- [:case_sensitive, :case_insensitive] do
          assert Value.regex_match(t("ab"), t(pattern), mode) == {:unsupported, :regex_not_literal}, inspect(pattern)
        end
      end
    end

    test "the *** director and (? embedded options are covered" do
      for pattern <- ["***=a.b", "***:a", "(?i)abc", "(?x)a b"] do
        assert Value.regex_match(t("a.b"), t(pattern), :case_sensitive) == {:unsupported, :regex_not_literal}
      end
    end

    test "is unsupported even for a NULL subject, because Postgres can compile a constant pattern while planning" do
      assert Value.regex_match(nil, t("("), :case_sensitive) == {:unsupported, :regex_not_literal}
      assert Value.regex_match(nil, t("a.*"), :case_insensitive) == {:unsupported, :regex_not_literal}
    end

    test "an unsupported argument still wins over a non-literal pattern" do
      assert Value.regex_match(@boom, t("("), :case_sensitive) == @boom
      assert Value.regex_match(t("a"), @boom, :case_sensitive) == @boom
    end
  end

  describe "regex_match/3 with literal patterns, case sensitive" do
    for {subject, pattern, result} <- [
          # unanchored substring match
          {"public:lobby", "public:lobby", true},
          {"xpublic:lobbyy", "public:lobby", true},
          {"abc", "a", true},
          {"abc", "b", true},
          {"abc", "c", true},
          {"abc", "ab", true},
          {"abc", "bc", true},
          {"abc", "abc", true},
          {"abc", "abcd", false},
          {"abc", "ac", false},
          {"abc", "d", false},
          {"aab", "ab", true},
          {"", "a", false},
          # the empty pattern matches everything, including the empty string
          {"", "", true},
          {"abc", "", true},
          # case matters
          {"ABC", "abc", false},
          {"abc", "ABC", false},
          {"Public:Lobby", "public", false},
          # characters that look special but are literal in an advanced regex outside brackets
          {"a-b", "-", true},
          {"a/b", "/", true},
          {"a:b", ":", true},
          {"a#b", "#", true},
          {"a b", " ", true},
          {"a\tb", "\t", true},
          {"a\nb", "\n", true},
          {"a%b", "%", true},
          {"a_b", "_", true},
          {"a}b", "}", true},
          {"a]b", "]", true},
          {"a&b", "&", true},
          {"a'b", "'", true},
          {"a\"b", "\"", true},
          {"a=b", "=", true},
          {"a<b>", "<b>", true},
          {"a!b", "!", true},
          {"a@b", "@", true},
          {"a~b", "~", true},
          {"a,b", ",", true},
          {"a;b", ";", true},
          {"a`b", "`", true},
          {"line1\nline2", "e1\nl", true},
          {"ab", "a b", false},
          # non-ASCII text works for the case-sensitive operator: same code points, same bytes
          {"café", "é", true},
          {"café", "É", false},
          {"café", "cafe", false},
          {"日本語", "本", true},
          {"😀 ok", "😀", true}
        ] do
      test "#{inspect(subject)} ~ #{inspect(pattern)} is #{result}" do
        assert Value.regex_match(t(unquote(subject)), t(unquote(pattern)), :case_sensitive) == unquote(result)
      end
    end
  end

  describe "regex_match/3 with literal patterns, case insensitive" do
    for {subject, pattern, result} <- [
          {"PUBLIC:LOBBY", "public:lobby", true},
          {"public:lobby", "PUBLIC:LOBBY", true},
          {"Public:Lobby", "pUBLIC:lOBBY", true},
          {"xPUBLICy", "public", true},
          {"abc", "B", true},
          {"ABC", "b", true},
          {"abc", "abcd", false},
          {"abc", "d", false},
          {"", "a", false},
          {"abc", "", true},
          {"", "", true},
          # ASCII-only text folds by ASCII rules, including i and I
          {"I", "i", true},
          {"i", "I", true},
          {"TITLE", "title", true},
          # only letters fold
          {"a-b", "A-B", true},
          {"a_b", "A-B", false},
          {"[", "a", false}
        ] do
      test "#{inspect(subject)} ~* #{inspect(pattern)} is #{result}" do
        assert Value.regex_match(t(unquote(subject)), t(unquote(pattern)), :case_insensitive) == unquote(result)
      end
    end

    test "is unsupported when the subject or the pattern has a byte above 127" do
      # folding of non-ASCII letters depends on the collation provider and locale: on an ICU database
      # 'i' ~* 'İ' and 'I' ~* 'ı' are true, while the Kelvin sign U+212A doesn't match k
      for {subject, pattern} <- [
            {"café", "CAFÉ"},
            {"CAFÉ", "café"},
            {"café", "caf"},
            {"abc", "É"},
            {"é", "a"},
            {@kelvin, "k"},
            {"k", @kelvin},
            {"İ", "i"},
            {"i", "İ"},
            {"ß", "SS"},
            {"日本語", "本"},
            {"é", "é"}
          ] do
        assert Value.regex_match(t(subject), t(pattern), :case_insensitive) == {:unsupported, :regex_non_ascii},
               inspect({subject, pattern})
      end
    end

    test "an empty pattern matches non-ASCII text, since nothing is folded" do
      assert Value.regex_match(t("café"), t(""), :case_insensitive) == true
    end
  end

  describe "regex_match/3 arguments" do
    test "rejects an unknown mode" do
      assert_raise FunctionClauseError, fn -> Value.regex_match(t("a"), t("a"), :multiline) end
    end
  end
end
