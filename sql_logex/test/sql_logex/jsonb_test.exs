defmodule SqlLogex.JsonbTest do
  use ExUnit.Case, async: true

  alias SqlLogex.Jsonb

  # JSON texts are written in ~S sigils, where a backslash is literal: ~S|"\n"| is the JSON escape,
  # not an Elixir one.

  @boom {:unsupported, :boom}
  @bang {:unsupported, :bang}

  @invalid {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type json"}}
  @nul_escape {:unsupported, {:raises, :untranslatable_character, "unsupported Unicode escape sequence"}}

  @nbsp <<0xC2, 0xA0>>
  @bom <<0xEF, 0xBB, 0xBF>>

  defp parse(json), do: Jsonb.parse({:text, json})
  defp t(s), do: {:text, s}

  defp nested_lists(n), do: Enum.reduce(2..n//1, [], fn _, acc -> [acc] end)
  defp nested_objects(n), do: Enum.reduce(1..n, {:number, "1"}, fn _, acc -> %{"a" => acc} end)

  describe "parse/1 scalars and containers" do
    for {json, term} <- [
          {"null", :null},
          {"true", true},
          {"false", false},
          {~S|""|, ""},
          {~S|"a"|, "a"},
          {~S|"null"|, "null"},
          {"0", {:number, "0"}},
          {"[]", []},
          {"{}", %{}},
          {"[null]", [:null]},
          {~S|{"a":null}|, %{"a" => :null}},
          {"[true,false]", [true, false]},
          {~S|["a","b"]|, ["a", "b"]},
          {"[1,2,3]", [{:number, "1"}, {:number, "2"}, {:number, "3"}]},
          {~S|{"a":1}|, %{"a" => {:number, "1"}}},
          {~S|{"":1}|, %{"" => {:number, "1"}}},
          {~S|{"a":{"b":[true,false,null,"x",{"c":[]}]}}|, %{"a" => %{"b" => [true, false, :null, "x", %{"c" => []}]}}},
          {"[[],{},[[]],{\"a\":[]}]", [[], %{}, [[]], %{"a" => []}]},
          {"[[1,2],[3,[4]]]", [[{:number, "1"}, {:number, "2"}], [{:number, "3"}, [{:number, "4"}]]]}
        ] do
      test "decodes #{inspect(json)}" do
        assert parse(unquote(json)) == {:jsonb, unquote(Macro.escape(term))}
      end
    end

    test "JSON null is :null, not SQL NULL" do
      assert parse("null") == {:jsonb, :null}
      refute parse("null") == nil
    end

    test "allows whitespace around tokens, as Postgres does: space, tab, LF and CR" do
      assert parse(" \t\r\n[1]\n\t ") == {:jsonb, [{:number, "1"}]}
      assert parse(" \"a\" ") == {:jsonb, "a"}
      assert parse("\n1\n") == {:jsonb, {:number, "1"}}

      assert parse(" { \"a\" : [ 1 , true ] , \"b\" : null } ") ==
               {:jsonb, %{"a" => [{:number, "1"}, true], "b" => :null}}
    end
  end

  describe "parse/1 strings" do
    for {json, string} <- [
          {~S|"\b\f\n\r\t\"\\\/"|, "\b\f\n\r\t\"\\/"},
          {~S|"\u00e9"|, "é"},
          {~S|"\u00E9"|, "é"},
          {~S|"\u20ac"|, "€"},
          {~S|"\u0041\u0042"|, "AB"},
          {~S|"\u0001"|, <<1>>},
          {~S|"\u001f"|, <<31>>},
          {~S|"\u0020"|, " "},
          {~S|"\u007f"|, <<127>>},
          # surrogate pairs combine, in either case of hex digits
          {~S|"\ud83d\ude00"|, "😀"},
          {~S|"\uD83D\uDE00"|, "😀"},
          {~S|"\ud83d\uDE00"|, "😀"},
          {~S|"\ud800\udc00"|, <<0xF0, 0x90, 0x80, 0x80>>},
          {~S|"\udbff\udfff"|, <<0xF4, 0x8F, 0xBF, 0xBF>>},
          # non-characters are valid code points
          {~S|"\uffff"|, <<0xEF, 0xBF, 0xBF>>},
          {~S|"\ufffe"|, <<0xEF, 0xBF, 0xBE>>},
          # an escaped backslash before u0000 is a backslash, not a NUL escape
          {~S|"\\u0000"|, "\\u0000"},
          {~S|"a\\"|, "a\\"}
        ] do
      test "unescapes #{inspect(json)}" do
        assert parse(unquote(json)) == {:jsonb, unquote(string)}
      end
    end

    test "keeps raw non-ASCII text and a raw DEL character" do
      for string <- ["é", "日本語", "😀", "a\u007Fb", "\u0080", "\u{10FFFF}"] do
        assert parse(~s("#{string}")) == {:jsonb, string}
      end
    end

    test "unescapes keys too" do
      assert parse(~S|{"\u00e9":1,"a\nb":2}|) == {:jsonb, %{"é" => {:number, "1"}, "a\nb" => {:number, "2"}}}
    end
  end

  describe "parse/1 numbers" do
    for token <- [
          "0",
          "1",
          "-1",
          "10",
          "100",
          "123456789012345678901234567890",
          "-123456789012345678901234567890",
          "0.0",
          "-0.0",
          "0.5",
          "-0.5",
          "1.50",
          "0.10",
          "-12.375",
          "0.00001",
          # with both a fraction and an exponent the token passes through untouched
          "1.5e3",
          "1.5E3",
          "1.5e+3",
          "-1.5e-3",
          "10.25E2"
        ] do
      test "keeps the raw token #{token}" do
        assert parse(unquote(token)) == {:jsonb, {:number, unquote(token)}}
        assert parse("[" <> unquote(token) <> "]") == {:jsonb, [{:number, unquote(token)}]}
        assert parse(~s({"n": #{unquote(token)}})) == {:jsonb, %{"n" => {:number, unquote(token)}}}
      end
    end

    test "-0 comes out as 0, which is the same numeric value" do
      assert parse("-0") == {:jsonb, {:number, "0"}}
      assert parse("[-0]") == {:jsonb, [{:number, "0"}]}
    end

    # The decoder rewrites 1e5 as 1.0e5 before we see it, so such a token can't be told from a
    # genuine 1.0e5. jsonb prints 1e-5 as 0.00001 but 1.0e-5 as 0.000010.
    for token <- ["1e5", "1E5", "1e+5", "1e-5", "-1e5", "10e2", "0e0", "-0e5", "1.0e5", "1.0e-5", "1.0e+5", "100.0e1"] do
      test "is unsupported for the exponent token #{token}, whose raw form can't be recovered" do
        expected = {:unsupported, :jsonb_number_token}
        assert parse(unquote(token)) == expected
        assert parse("[1," <> unquote(token) <> "]") == expected
        assert parse("[" <> unquote(token) <> "]") == expected
        assert parse(~s({"n": #{unquote(token)}})) == expected
        assert parse(~s({"n": #{unquote(token)}, "m": 1})) == expected
      end
    end

    test "an exponent token does not hide a syntax error that comes before the check" do
      assert parse("[1e5 x]") == @invalid
    end

    test "is unsupported for numbers numeric_in could reject, which it does beyond its size limits" do
      range = {:unsupported, :jsonb_number_range}
      digits = fn n -> String.duplicate("9", n) end

      # the limits are 1000 bytes for the token, and 1000 for the magnitude of the exponent
      assert parse(digits.(1000)) == {:jsonb, {:number, digits.(1000)}}
      assert parse(digits.(1001)) == range
      assert parse("1." <> String.duplicate("0", 998)) == {:jsonb, {:number, "1." <> String.duplicate("0", 998)}}
      assert parse("1." <> String.duplicate("0", 999)) == range
      assert parse("1" <> String.duplicate("0", 150_000)) == range
      assert parse("[" <> digits.(1001) <> "]") == range

      assert parse("1.5e1000") == {:jsonb, {:number, "1.5e1000"}}
      assert parse("1.5e+1000") == {:jsonb, {:number, "1.5e+1000"}}
      assert parse("1.5e-1000") == {:jsonb, {:number, "1.5e-1000"}}
      assert parse("1.5e1001") == range
      assert parse("1.5e-1001") == range
      assert parse("1.5e999999") == range
      assert parse("1.5e-99999999999999999999") == range
    end

    for token <- [
          "01",
          "00",
          "-01",
          "+1",
          ".5",
          "-.5",
          "1.",
          "1.e5",
          "1e",
          "1e+",
          "1.5e",
          "-",
          "--1",
          "1.5.5",
          "1x",
          "0x10",
          "1e5e5",
          "- 1",
          "1 .5",
          "NaN",
          "Infinity",
          "-Infinity"
        ] do
      test "rejects the invalid number #{token}" do
        assert parse(unquote(token)) == @invalid
        assert parse("[" <> unquote(token) <> "]") == @invalid
      end
    end
  end

  describe "parse/1 duplicate object keys" do
    for {json, term} <- [
          {~S|{"a":1,"a":2}|, %{"a" => {:number, "2"}}},
          {~S|{"a":2,"a":1}|, %{"a" => {:number, "1"}}},
          {~S|{"a":"x","a":"y"}|, %{"a" => "y"}},
          {~S|{"a":1,"a":1,"a":3}|, %{"a" => {:number, "3"}}},
          {~S|{"a":"first","a":null}|, %{"a" => :null}},
          {~S|{"a":null,"a":"last"}|, %{"a" => "last"}},
          {~S|{"a":1,"b":2,"a":3,"b":null}|, %{"a" => {:number, "3"}, "b" => :null}},
          {~S|{"a":{"x":1},"a":[1]}|, %{"a" => [{:number, "1"}]}},
          {~S|{"a":[1],"a":{"x":1}}|, %{"a" => %{"x" => {:number, "1"}}}},
          {~S|{"":1,"":2}|, %{"" => {:number, "2"}}},
          # the same key spelled differently decodes to the same key
          {~S|{"é":1,"\u00e9":2}|, %{"é" => {:number, "2"}}},
          {~S|{"a":1,"\u0061":2}|, %{"a" => {:number, "2"}}},
          # different case is a different key
          {~S|{"A":"upper","a":"lower"}|, %{"A" => "upper", "a" => "lower"}},
          # only an object's own keys are merged
          {~S|[{"a":1},{"a":2}]|, [%{"a" => {:number, "1"}}, %{"a" => {:number, "2"}}]},
          {~S|{"o":{"a":1,"a":2},"a":3}|, %{"o" => %{"a" => {:number, "2"}}, "a" => {:number, "3"}}},
          {~S|{"o":{"a":1},"o":{"b":2}}|, %{"o" => %{"b" => {:number, "2"}}}}
        ] do
      test "the last value wins in #{inspect(json)}" do
        assert parse(unquote(json)) == {:jsonb, unquote(Macro.escape(term))}
      end
    end
  end

  describe "parse/1 NUL escape" do
    for {name, json} <- [
          {"a string value", ~S|"a\u0000b"|},
          {"a whole string", ~S|"\u0000"|},
          {"an object key", ~S|{"a\u0000":1}|},
          {"a key that is only the escape", ~S|{"\u0000":1}|},
          {"an object value", ~S|{"a":"\u0000"}|},
          {"an array element", ~S|["\u0000"]|},
          {"a nested value", ~S|{"a":[{"b":"x\u0000"}]}|},
          {"a later value", ~S|{"a":"ok","b":"\u0000"}|},
          {"followed by more digits", ~S|"\u00000"|},
          {"among other escapes", ~S|"\n\u0000\t"|},
          {"a claim like a sub", ~S|{"sub":"a0eebc99-9c0b-4ef8-bb6d-6bb9bd38\u00000a11"}|}
        ] do
      test "raises for #{name}" do
        assert parse(unquote(json)) == @nul_escape
      end
    end

    test "raises even when the same key later has a valid value" do
      assert parse(~S|{"a":"\u0000","a":"x"}|) == @nul_escape
    end

    test "other control-character escapes are fine" do
      assert parse(~S|"\u0001\u0008\u001f"|) == {:jsonb, <<1, 8, 31>>}
    end
  end

  describe "parse/1 unpaired surrogates" do
    for {name, json} <- [
          {"a lone high surrogate", ~S|"\ud800"|},
          {"a lone high surrogate, upper case", ~S|"\uD83D"|},
          {"a lone low surrogate", ~S|"\udc00"|},
          {"a lone low surrogate, upper case", ~S|"\uDFFF"|},
          {"a high surrogate and a non-surrogate escape", ~S|"\ud800\u0041"|},
          {"a high surrogate and a plain character", ~S|"\ud800x"|},
          {"a high surrogate and a simple escape", ~S|"\ud83d\n"|},
          {"a high surrogate and an escaped backslash", ~S|"\ud83d\\"|},
          {"two high surrogates", ~S|"\ud800\ud800"|},
          {"two high surrogates then a low one", ~S|"\ud800\ud800\udc00"|},
          {"a low surrogate before a high one", ~S|"\udc00\ud800"|},
          {"two low surrogates", ~S|"\udc00\udc00"|},
          {"a high surrogate at the end of the string", ~S|"a\ud83d"|},
          {"a high surrogate in a key", ~S|{"\ud800":1}|},
          {"a high surrogate in a value", ~S|{"a":"\ud800"}|}
        ] do
      test "raises for #{name}" do
        assert parse(unquote(json)) == @invalid
      end
    end
  end

  describe "parse/1 invalid JSON" do
    for {name, json} <- [
          {"the empty string", ""},
          {"only whitespace", " \t\r\n"},
          {"an unterminated array", "[1"},
          {"an unterminated object", ~S|{"a":1|},
          {"an unterminated string", ~S|"abc|},
          {"a lone quote", ~S|"|},
          {"a lone backslash in a string", "\"\\"},
          {"a lone bracket", "["},
          {"a lone brace", "{"},
          {"a trailing comma in an array", "[1,]"},
          {"a leading comma in an array", "[,1]"},
          {"a doubled comma", "[1,,2]"},
          {"a trailing comma in an object", ~S|{"a":1,}|},
          {"a leading comma in an object", ~S|{,"a":1}|},
          {"a missing comma in an array", "[1 2]"},
          {"a missing comma in an object", ~S|{"a":1 "b":2}|},
          {"a missing colon", ~S|{"a" 1}|},
          {"a missing value", ~S|{"a":}|},
          {"a key without a value", ~S|{"a"}|},
          {"an unquoted key", "{a:1}"},
          {"a single-quoted key", "{'a':1}"},
          {"a single-quoted string", "'a'"},
          {"a number as a key", "{1:1}"},
          {"an extra closing brace", ~S|{"a":1}}|},
          {"an extra closing bracket", "[1]]"},
          {"two values", "1 2"},
          {"two arrays", "[1][2]"},
          {"two objects", "{} {}"},
          {"two strings", ~S|"a" "b"|},
          {"garbage after a value", "[1] x"},
          {"truncated true", "tru"},
          {"truncated null", "nul"},
          {"truncated false", "fals"},
          {"capitalised True", "True"},
          {"upper case TRUE", "TRUE"},
          {"upper case NULL", "NULL"},
          {"true with trailing letters", "truee"},
          {"null with trailing letters", "nulll"},
          {"undefined", "undefined"},
          {"nan", "nan"},
          {"a bare word", "abc"},
          {"a comment", "/**/1"},
          {"a trailing comment", "[1]//x"},
          {"an invalid escape \\x", ~S|"\x"|},
          {"an escaped single quote", ~S|"\'"|},
          {"an escaped zero", ~S|"\0"|},
          {"a short \\u escape", ~S|"\u12"|},
          {"a non-hex \\u escape", ~S|"\u12G4"|},
          {"a \\u escape with no digits", ~S|"\u"|},
          {"a raw tab in a string", "\"a\tb\""},
          {"a raw newline in a string", "\"a\nb\""},
          {"a raw carriage return in a string", "\"a\rb\""},
          {"a raw control character 0x01 in a string", "\"a" <> <<1>> <> "b\""},
          {"a raw control character 0x1F in a string", "\"a" <> <<31>> <> "b\""},
          {"a raw tab in a key", "{\"a\tb\":1}"},
          {"a form feed before the value", "\f1"},
          {"a vertical tab before the value", "\v1"},
          {"a form feed after the value", "1\f"},
          {"a non-breaking space before the value", @nbsp <> ~S|"a"|},
          {"a non-breaking space after the value", ~S|"a"| <> @nbsp},
          {"a byte order mark before the value", @bom <> ~S|"a"|}
        ] do
      test "raises for #{name}" do
        assert parse(unquote(json)) == @invalid
      end
    end

    test "raises for an upper case \\U escape, which JSON doesn't have" do
      assert Jsonb.parse({:text, ~S|"\U0041"|}) == @invalid
    end
  end

  describe "parse/1 text that isn't valid UTF-8" do
    for {name, json} <- [
          {"a stray continuation byte", <<?", 0xFF, ?">>},
          {"a truncated sequence", <<?", 0xC3, ?">>},
          {"an overlong encoding", <<?", 0xC0, 0x80, ?">>},
          {"an encoded surrogate", <<?", 0xED, 0xA0, 0x80, ?">>},
          {"a code point above U+10FFFF", <<?", 0xF4, 0x90, 0x80, 0x80, ?">>},
          {"a stray byte outside a string", <<0xFF>>},
          {"a stray byte after the value", <<?1, 0xFF>>}
        ] do
      test "is unsupported for #{name}, which a Postgres text value can't be" do
        assert parse(unquote(json)) == {:unsupported, :invalid_utf8}
      end
    end
  end

  describe "parse/1 nesting" do
    test "decodes 100 levels of nesting" do
      assert parse(String.duplicate("[", 100) <> String.duplicate("]", 100)) == {:jsonb, nested_lists(100)}

      assert parse(String.duplicate(~S|{"a":|, 100) <> "1" <> String.duplicate("}", 100)) ==
               {:jsonb, nested_objects(100)}
    end

    test "is unsupported beyond 100 levels, which Postgres still allows" do
      too_deep = {:unsupported, :jsonb_too_deeply_nested}
      assert parse(String.duplicate("[", 101) <> String.duplicate("]", 101)) == too_deep
      assert parse(String.duplicate(~S|{"a":|, 101) <> "1" <> String.duplicate("}", 101)) == too_deep
      assert parse(String.duplicate("[", 5000) <> String.duplicate("]", 5000)) == too_deep
      assert parse(String.duplicate(~S|[{"a":|, 51) <> "1" <> String.duplicate("}]", 51)) == too_deep
    end

    test "counts depth along a path, not across siblings" do
      siblings = "[" <> Enum.map_join(1..300, ",", fn _ -> "[[]]" end) <> "]"
      assert {:jsonb, list} = parse(siblings)
      assert length(list) == 300

      wide = "{" <> Enum.map_join(1..300, ",", fn i -> ~s("k#{i}":{"a":[1]}) end) <> "}"
      assert {:jsonb, map} = parse(wide)
      assert map_size(map) == 300
    end

    test "a deep but invalid document is invalid, not too deep" do
      assert parse(String.duplicate("[", 50) <> String.duplicate("]", 49)) == @invalid
    end
  end

  describe "parse/1 arguments" do
    test "NULL is NULL" do
      assert Jsonb.parse(nil) == nil
    end

    test "an unsupported argument is returned unchanged" do
      assert Jsonb.parse(@boom) == @boom
    end
  end

  describe "object_field_text/2" do
    @doc_json ~S|{"s":"x","empty":"","esc":"a\n\u00e9","t":true,"f":false,"nul":null,"n":1,"fl":1.5,"o":{"a":1},"eo":{},"arr":[1],"ea":[],"str_true":"true","str_null":"null","str_num":"1"}|

    defp field(key), do: Jsonb.object_field_text(parse(@doc_json), t(key))

    test "returns a string unescaped" do
      assert field("s") == t("x")
      assert field("esc") == t("a\né")
      assert field("str_true") == t("true")
      assert field("str_null") == t("null")
      assert field("str_num") == t("1")
    end

    test "returns the empty string for an empty JSON string, which is not NULL" do
      assert field("empty") == t("")
    end

    test "returns true and false as text" do
      assert field("t") == t("true")
      assert field("f") == t("false")
    end

    test "returns NULL for JSON null and for a missing key" do
      assert field("nul") == nil
      assert field("missing") == nil
      assert field("") == nil
    end

    test "is unsupported for a number, which Postgres prints from its normalised value" do
      assert field("n") == {:unsupported, :jsonb_number_text}
      assert field("fl") == {:unsupported, :jsonb_number_text}
    end

    test "is unsupported for an object or an array, which Postgres prints as JSON text" do
      for key <- ["o", "eo", "arr", "ea"] do
        assert field(key) == {:unsupported, :jsonb_container_text}, key
      end
    end

    test "matches the key exactly, byte for byte" do
      doc = parse(~S|{"a":"lower","A":"upper","é":"accent","a b":"space","":"empty"}|)
      assert Jsonb.object_field_text(doc, t("a")) == t("lower")
      assert Jsonb.object_field_text(doc, t("A")) == t("upper")
      assert Jsonb.object_field_text(doc, t("é")) == t("accent")
      assert Jsonb.object_field_text(doc, t("a b")) == t("space")
      assert Jsonb.object_field_text(doc, t("")) == t("empty")
      assert Jsonb.object_field_text(doc, t("a ")) == nil
      assert Jsonb.object_field_text(doc, t("É")) == nil
    end

    test "sees the last of duplicate keys" do
      assert Jsonb.object_field_text(parse(~S|{"a":"first","a":"last"}|), t("a")) == t("last")
      assert Jsonb.object_field_text(parse(~S|{"a":"first","a":null}|), t("a")) == nil
      assert Jsonb.object_field_text(parse(~S|{"a":null,"a":"last"}|), t("a")) == t("last")
    end

    test "returns NULL when the root is not an object, whatever the key" do
      for json <- ["[1,2]", ~S|["a"]|, ~S|[{"a":"x"}]|, "[]", ~S|"a"|, "1", "1.5", "true", "false", "null"] do
        assert Jsonb.object_field_text(parse(json), t("a")) == nil, json
        assert Jsonb.object_field_text(parse(json), t("0")) == nil, json
      end
    end

    test "returns NULL for an empty object" do
      assert Jsonb.object_field_text(parse("{}"), t("a")) == nil
    end

    test "only looks at the top level" do
      doc = parse(~S|{"a":{"b":"nested"},"b":"top"}|)
      assert Jsonb.object_field_text(doc, t("b")) == t("top")
    end

    test "reads claims the way auth.uid() does" do
      claims = parse(~S|{"sub":"A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11","role":"authenticated","exp":1700000000}|)
      assert Jsonb.object_field_text(claims, t("sub")) == t("A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11")
      assert Jsonb.object_field_text(claims, t("role")) == t("authenticated")
      assert Jsonb.object_field_text(claims, t("exp")) == {:unsupported, :jsonb_number_text}
      assert Jsonb.object_field_text(claims, t("missing")) == nil
    end

    test "is strict: NULL in either argument is NULL" do
      assert Jsonb.object_field_text(nil, t("a")) == nil
      assert Jsonb.object_field_text(parse(~S|{"a":"x"}|), nil) == nil
      assert Jsonb.object_field_text(nil, nil) == nil
    end

    test "returns an unsupported argument unchanged, the first one winning, even next to NULL" do
      doc = parse(~S|{"a":"x"}|)
      assert Jsonb.object_field_text(@boom, t("a")) == @boom
      assert Jsonb.object_field_text(doc, @boom) == @boom
      assert Jsonb.object_field_text(nil, @boom) == @boom
      assert Jsonb.object_field_text(@boom, nil) == @boom
      assert Jsonb.object_field_text(@boom, @bang) == @boom
    end

    test "passes through the result of an unsupported parse" do
      assert Jsonb.object_field_text(parse(~S|{"a":"\u0000"}|), t("a")) == @nul_escape
      assert Jsonb.object_field_text(parse(""), t("a")) == @invalid
      assert Jsonb.object_field_text(parse(~S|{"a":1e5}|), t("a")) == {:unsupported, :jsonb_number_token}
    end
  end
end
