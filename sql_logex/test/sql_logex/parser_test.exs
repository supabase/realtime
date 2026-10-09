defmodule SqlLogex.ParserTest.Trees do
  @moduledoc false
  # Shorthand for building the trees the tests expect. It lives in its own module because the
  # tests below generate test cases at compile time, where the test module's own functions don't exist yet.

  def text(value), do: {:cast, {:const, :string, value}, "text"}
  def col(name), do: {:column, name}
  def number(raw), do: {:const, :number, raw}
  def topic, do: {:func, "realtime", "topic", []}
  def uid, do: {:func, "auth", "uid", []}
end

defmodule SqlLogex.ParserTest do
  use ExUnit.Case, async: true

  import SqlLogex.ParserTest.Trees

  alias SqlLogex.Deparse
  alias SqlLogex.Parser

  # What Postgres reported for the policies in test/support/sql_logex_policies.ex, per major version.
  @catalogs Enum.map(~w(pg17 pg15), fn version ->
              {catalog, _binding} = Code.eval_file(Path.expand("../fixtures/#{version}/catalog.exs", __DIR__))
              {version, catalog}
            end)

  # Every non-nil `pg_get_expr` output in the fixtures.
  @expressions for {version, catalog} <- @catalogs,
                   policy <- catalog.policies,
                   {kind, text} <- [qual: policy.qual, with_check: policy.with_check],
                   text != nil,
                   do: %{version: version, name: policy.name, kind: kind, text: text}

  # The expressions that are CASE, EXISTS or a subselect with FROM. Postgres prints them over several
  # lines, and none of them is part of the supported grammar.
  @unsupported_policies ~w(
    generator_slow_read generator_slow_write grammar_case_searched grammar_case_simple grammar_exists
  )

  @missing_raw "(EXISTS ( SELECT 1\n   FROM t\n  WHERE (x = y)))"
  @missing {:unsupported, @missing_raw}

  # Inserted at every position of every fixture expression by the mutation test.
  @inserts ["x", ")", "(", "'", "\"", " ", "\n", ",", "::", "é"]

  # Parses `input`, checks that it prints back unchanged, and returns the tree.
  defp parse!(input) do
    ast = Parser.parse(input)
    assert Deparse.to_string(ast) == input
    ast
  end

  defp unsupported_nodes({:unsupported, raw}), do: [raw]
  defp unsupported_nodes(node) when is_tuple(node), do: node |> Tuple.to_list() |> unsupported_nodes()
  defp unsupported_nodes(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &unsupported_nodes/1)
  defp unsupported_nodes(_leaf), do: []

  defp policy_text(version, name) do
    {^version, catalog} = List.keyfind(@catalogs, version, 0)
    policy = Enum.find(catalog.policies, &(&1.name == name)) || flunk("no policy #{name} in the #{version} fixture")
    policy.qual || policy.with_check
  end

  # `text` cut off at every position, with each byte deleted, and with each of `@inserts` added.
  defp mutations(text) do
    size = byte_size(text)

    Enum.flat_map(0..size, fn position ->
      head = binary_part(text, 0, position)
      tail = binary_part(text, position, size - position)
      deleted = if tail == "", do: [], else: [head <> binary_part(tail, 1, byte_size(tail) - 1)]

      [head] ++ deleted ++ for(insert <- @inserts, do: head <> insert <> tail)
    end)
  end

  describe "round trip over the fixtures" do
    for %{version: version, name: name, kind: kind, text: text} <- @expressions do
      test "#{version} #{name} (#{kind})" do
        assert Deparse.to_string(Parser.parse(unquote(text))) == unquote(text)
      end
    end

    test "the fixtures hold the expressions this suite is written for" do
      for {version, catalog} <- @catalogs do
        multi_line =
          for policy <- catalog.policies, text = policy.qual || policy.with_check, text =~ "\n", do: policy.name

        assert Enum.sort(multi_line) == Enum.sort(@unsupported_policies), "#{version}: multi-line policies changed"
      end
    end
  end

  describe "supported grammar leaves nothing unsupported" do
    for %{version: version, name: name, kind: kind, text: text} <- @expressions, name not in @unsupported_policies do
      test "#{version} #{name} (#{kind})" do
        assert unsupported_nodes(Parser.parse(unquote(text))) == []
      end
    end

    for %{version: version, name: name, kind: kind, text: text} <- @expressions, name in @unsupported_policies do
      test "#{version} #{name} (#{kind}) is unsupported as a whole, text unchanged" do
        assert Parser.parse(unquote(text)) == {:unsupported, unquote(text)}
      end
    end
  end

  describe "exact trees for the user-channel policies" do
    for {version, _catalog} <- @catalogs do
      test "#{version} lobby" do
        assert Parser.parse(policy_text(unquote(version), "lobby")) ==
                 {:op, "~*", topic(), text("public:lobby")}
      end

      for {name, uid} <- [
            {"users receive on own channel", :call},
            {"users send on own channel", :call},
            {"users receive on own channel (initplan)", :sublink},
            {"users send on own channel (initplan)", :sublink}
          ] do
        test "#{version} #{name}" do
          uid = if unquote(uid) == :call, do: uid(), else: {:sublink, uid(), "uid"}

          assert Parser.parse(policy_text(unquote(version), unquote(name))) ==
                   {:bool_expr, :and,
                    [
                      {:op, "=", topic(), {:op, "||", text("user:"), uid}},
                      {:scalar_array_op, "=", :any, col("extension"), {:array, [text("broadcast"), text("presence")]}}
                    ]}
        end
      end
    end
  end

  describe "exact trees for the grammar policies" do
    claims = {:cast, {:func, nil, "current_setting", [text("request.jwt.claims"), {:const, :bool, true}]}, "jsonb"}

    expected = [
      {"grammar_not_in",
       {:scalar_array_op, "<>", :all, col("extension"), {:array, [text("broadcast"), text("presence")]}}},
      {"grammar_in_single", {:op, "=", col("extension"), text("broadcast")}},
      {"grammar_not", {:not, {:op, "=", topic(), text("x")}}},
      {"grammar_is_null", {:null_test, :is_null, topic()}},
      {"grammar_is_not_null", {:null_test, :is_not_null, topic()}},
      {"grammar_coalesce", {:op, "=", {:coalesce, [topic(), text("x")]}, text("x")}},
      {"grammar_nullif", {:op, "=", {:nullif, topic(), text("x")}, text("y")}},
      {"grammar_claims_text", {:op, "=", {:op, "->>", claims, text("k")}, text("v")}},
      {"grammar_claims_boolean", {:cast, {:op, "->>", claims, text("k")}, "boolean"}},
      {"grammar_doubled_quote", {:op, "=", topic(), text("it's")}},
      {"grammar_eq_null", {:op, "=", topic(), {:cast, {:const, :null}, "text"}}},
      {"grammar_concat_null", {:op, "=", topic(), {:op, "||", text("x"), {:cast, {:const, :null}, "text"}}}},
      {"grammar_auth_role", {:op, "=", {:func, "auth", "role", []}, text("authenticated")}},
      {"grammar_jwt_text_initplan",
       {:op, "=", {:sublink, {:op, "->>", {:func, "auth", "jwt", []}, text("k")}, nil}, text("v")}},
      {"generator_authenticated_read_matching_user_sub",
       {:op, "=", {:cast, {:sublink, uid(), "uid"}, "text"}, text("c0ffee00-1111-4222-8333-444455556666")}},
      {"generator_broken_read_presence", {:sublink, {:func, "public", "test_log_error", []}, "test_log_error"}},
      {"grammar_true", {:const, :bool, true}},
      {"grammar_false", {:const, :bool, false}},
      {"grammar_and_three",
       {:bool_expr, :and,
        [
          {:op, "=", topic(), text("a")},
          {:op, "=", col("extension"), text("broadcast")},
          {:op, "=", col("private"), {:const, :bool, true}}
        ]}},
      {"grammar_or_in_and",
       {:bool_expr, :and,
        [
          {:bool_expr, :or, [{:op, "=", topic(), text("a")}, {:op, "=", topic(), text("b")}]},
          {:op, "=", col("extension"), text("broadcast")}
        ]}},
      {"generator_authenticated_read_broadcast_based_on_claim",
       {:bool_expr, :and,
        [
          {:op, "=", topic(), text("fixture_topic")},
          {:op, "=", col("extension"), text("broadcast")},
          {:coalesce, [{:cast, {:op, "->>", claims, text("broadcast_read")}, "boolean"}, {:const, :bool, false}]}
        ]}}
    ]

    for {version, _catalog} <- @catalogs, {name, ast} <- expected do
      test "#{version} #{name}" do
        assert Parser.parse(policy_text(unquote(version), unquote(name))) == unquote(Macro.escape(ast))
      end
    end
  end

  # Forms Postgres prints that none of the fixture policies use. Most are what PG17's pg_get_expr
  # returned for the expression in the comment above them, on a scratch table.
  describe "other canonical forms" do
    cases = [
      # n = 1::float8
      {"(1)::double precision", {:cast, number("1"), "double precision"}},
      # id = -1
      {"'-1'::integer", {:cast, {:const, :string, "-1"}, "integer"}},
      # n = 1.5
      {"(n = 1.5)", {:op, "=", col("n"), number("1.5")}},
      # ts > '2020-01-01'
      {"(ts > '2020-01-01 00:00:00+00'::timestamp with time zone)",
       {:op, ">", col("ts"), {:cast, {:const, :string, "2020-01-01 00:00:00+00"}, "timestamp with time zone"}}},
      # "User"::varchar(3)::text = 'a'
      {"(((c)::character varying(3))::text = 'a'::text)",
       {:op, "=", {:cast, {:cast, col("c"), "character varying(3)"}, "text"}, text("a")}},
      # ts::timestamp(3) = now()::timestamp
      {"((ts)::timestamp(3) without time zone = now())",
       {:op, "=", {:cast, col("ts"), "timestamp(3) without time zone"}, {:func, nil, "now", []}}},
      # id::numeric(10,2) = 1
      {"((n)::numeric(10,2) = 1)", {:op, "=", {:cast, col("n"), "numeric(10,2)"}, number("1")}},
      # "User"::text[] = tags
      {"((\"User\")::text[] = tags)", {:op, "=", {:cast, col("User"), "text[]"}, col("tags")}},
      # tags = ARRAY[]::text[]
      {"(a = ANY (ARRAY[]::text[]))", {:scalar_array_op, "=", :any, col("a"), {:cast, {:array, []}, "text[]"}}},
      {"((a)::public.status = 'x'::public.status)",
       {:op, "=", {:cast, col("a"), "public.status"}, {:cast, {:const, :string, "x"}, "public.status"}}},
      # "User" = ANY(tags) and "User" <> ALL('{a,b}'::text[])
      {"(\"User\" = ANY (tags))", {:scalar_array_op, "=", :any, col("User"), col("tags")}},
      {"(a <> ALL ('{a,b}'::text[]))",
       {:scalar_array_op, "<>", :all, col("a"), {:cast, {:const, :string, "{a,b}"}, "text[]"}}},
      # operators are read generically, the resolver decides which of them exist
      {"(a #>> b)", {:op, "#>>", col("a"), col("b")}},
      {"(a !~* 'x'::text)", {:op, "!~*", col("a"), text("x")}},
      # j ?| ARRAY['a','b']
      {"(a ?| ARRAY['a'::text, 'b'::text])", {:op, "?|", col("a"), {:array, [text("a"), text("b")]}}},
      # identifiers are quoted only when Postgres would quote them
      {"(\"order\" = 'o'::text)", {:op, "=", col("order"), text("o")}},
      {"(\"has space\" IS NULL)", {:null_test, :is_null, col("has space")}},
      {~s|("a""b" IS NULL)|, {:null_test, :is_null, col(~s(a"b))}},
      # left("User", 1) = 'a'
      {"(\"left\"(\"User\", 1) = 'a'::text)", {:op, "=", {:func, nil, "left", [col("User"), number("1")]}, text("a")}},
      {"public.my_func(a, b)", {:func, "public", "my_func", [col("a"), col("b")]}},
      {~s|"My Schema"."My Func"()|, {:func, "My Schema", "My Func", []}},
      {"'it''s'", {:const, :string, "it's"}},
      {"''::text", {:cast, {:const, :string, ""}, "text"}},
      {"'multi\nline'::text", text("multi\nline")},
      {"'é'::text", text("é")},
      {"NULL", {:const, :null}},
      {"(NULL::integer IS NULL)", {:null_test, :is_null, {:cast, {:const, :null}, "integer"}}},
      {"COALESCE(a, b, 1)", {:coalesce, [col("a"), col("b"), number("1")]}},
      {"((a)::text IS NOT NULL)", {:null_test, :is_not_null, {:cast, col("a"), "text"}}},
      {"(NOT (NOT b))", {:not, {:not, col("b")}}},
      {"(( SELECT auth.uid() AS uid) = u)", {:op, "=", {:sublink, uid(), "uid"}, col("u")}},
      {"((a OR b) AND (c OR d))",
       {:bool_expr, :and, [{:bool_expr, :or, [col("a"), col("b")]}, {:bool_expr, :or, [col("c"), col("d")]}]}}
    ]

    for {input, ast} <- cases do
      test "#{inspect(input)}" do
        assert parse!(unquote(input)) == unquote(Macro.escape(ast))
      end
    end
  end

  describe "recovery" do
    test "the example from the brief: EXISTS as the last OR operand" do
      input = "((realtime.topic() = 'a'::text) OR #{@missing_raw})"
      assert parse!(input) == {:bool_expr, :or, [{:op, "=", topic(), text("a")}, @missing]}
    end

    for {op, tag} <- [{"AND", :and}, {"OR", :or}] do
      test "unsupported first, middle and last in #{op}" do
        op = unquote(op)
        a = {:op, "=", col("a"), text("a")}
        b = {:op, "=", col("b"), text("b")}

        assert parse!("(#{@missing_raw} #{op} (a = 'a'::text) #{op} (b = 'b'::text))") ==
                 {:bool_expr, unquote(tag), [@missing, a, b]}

        assert parse!("((a = 'a'::text) #{op} #{@missing_raw} #{op} (b = 'b'::text))") ==
                 {:bool_expr, unquote(tag), [a, @missing, b]}

        assert parse!("((a = 'a'::text) #{op} (b = 'b'::text) #{op} #{@missing_raw})") ==
                 {:bool_expr, unquote(tag), [a, b, @missing]}
      end
    end

    test "every operand unsupported" do
      assert parse!("((EXISTS (x)) AND (EXISTS (y)))") ==
               {:bool_expr, :and, [{:unsupported, "(EXISTS (x))"}, {:unsupported, "(EXISTS (y))"}]}
    end

    test "unsupported inside NOT" do
      assert parse!("(NOT #{@missing_raw})") == {:not, @missing}
      assert parse!("(NOT m.topic)") == {:not, {:unsupported, "m.topic"}}
    end

    test "unsupported inside an operator operand, on either side" do
      assert parse!("(m.topic = 'x'::text)") == {:op, "=", {:unsupported, "m.topic"}, text("x")}
      assert parse!("('x'::text = m.topic)") == {:op, "=", text("x"), {:unsupported, "m.topic"}}
      assert parse!("(m.topic = n.topic)") == {:op, "=", {:unsupported, "m.topic"}, {:unsupported, "n.topic"}}

      assert parse!("(\nCASE\n    WHEN a THEN 1\n    ELSE 2\nEND = 1)") ==
               {:op, "=", {:unsupported, "\nCASE\n    WHEN a THEN 1\n    ELSE 2\nEND"}, number("1")}
    end

    test "unsupported inside other constructs" do
      assert parse!("(a = ANY ( SELECT y\n FROM t))") ==
               {:scalar_array_op, "=", :any, col("a"), {:unsupported, " SELECT y\n FROM t"}}

      assert parse!("(a = ANY (ARRAY[m.x, 'b'::text]))") ==
               {:scalar_array_op, "=", :any, col("a"), {:array, [{:unsupported, "m.x"}, text("b")]}}

      assert parse!("COALESCE(m.x, 'b'::text)") == {:coalesce, [{:unsupported, "m.x"}, text("b")]}
      assert parse!("NULLIF(a, m.x)") == {:nullif, col("a"), {:unsupported, "m.x"}}

      assert parse!("f(a, m.x, EXTRACT(epoch FROM ts))") ==
               {:func, nil, "f", [col("a"), {:unsupported, "m.x"}, {:unsupported, "EXTRACT(epoch FROM ts)"}]}

      assert parse!("((m.x)::text = 'a'::text)") == {:op, "=", {:cast, {:unsupported, "m.x"}, "text"}, text("a")}
      assert parse!("(m.x IS NULL)") == {:null_test, :is_null, {:unsupported, "m.x"}}
    end

    test "a run skips quoted text, brackets and nested groups" do
      # A quote holding `) OR (` must not end the run, and a doubled quote must not end the literal.
      assert parse!("((a = 'x'::text) AND (EXISTS (SELECT ') OR (' FROM t)) AND (b = 'y'::text))") ==
               {:bool_expr, :and,
                [
                  {:op, "=", col("a"), text("x")},
                  {:unsupported, "(EXISTS (SELECT ') OR (' FROM t))"},
                  {:op, "=", col("b"), text("y")}
                ]}

      assert parse!("((EXISTS (SELECT 'it''s) OR (' FROM t)) OR b)") ==
               {:bool_expr, :or, [{:unsupported, "(EXISTS (SELECT 'it''s) OR (' FROM t))"}, col("b")]}

      assert parse!("(x[')'] = 'a'::text)") == {:op, "=", {:unsupported, "x[')']"}, text("a")}
      assert parse!("(tags[1] = 'a'::text)") == {:op, "=", {:unsupported, "tags[1]"}, text("a")}
      assert parse!(~s|("a)b".c = 'x'::text)|) == {:op, "=", {:unsupported, ~s|"a)b".c|}, text("x")}

      assert parse!("(f(a, b, (c AND d)) OR e)") ==
               {:bool_expr, :or,
                [{:func, nil, "f", [col("a"), col("b"), {:bool_expr, :and, [col("c"), col("d")]}]}, col("e")]}

      assert parse!("(EXISTS (a, (b), [c]) AND d)") ==
               {:bool_expr, :and, [{:unsupported, "EXISTS (a, (b), [c])"}, col("d")]}
    end

    test "a subselect with FROM is unsupported as a whole, not a sublink around a fragment" do
      raw = "( SELECT true\n   FROM pg_sleep((1)::double precision) pg_sleep(pg_sleep))"
      assert parse!(raw) == {:unsupported, raw}

      raw = "( SELECT max(pt_1.id) AS max\n   FROM pt pt_1)"
      assert parse!("(id = #{raw})") == {:op, "=", col("id"), {:unsupported, raw}}
    end

    test "input that can't be parsed at all is the whole text" do
      for input <- [
            "\nCASE\n    WHEN a THEN true\n    ELSE false\nEND",
            "",
            "   ",
            ")",
            "(",
            "((a = 'x'::text)",
            "(a = 'x'::text))",
            ")(",
            "'unterminated",
            ~s|"unterminated|,
            "[",
            "]]",
            "!!!",
            "SELECT * FROM t",
            "a, b",
            <<255, 254>>,
            <<?(, 255, ?)>>,
            "(a = 'x'::text) AND",
            "AND (a = 'x'::text)"
          ] do
        assert Parser.parse(input) == {:unsupported, input}
        assert Deparse.to_string(Parser.parse(input)) == input
      end
    end
  end

  describe "no byte is dropped" do
    test "trailing junk makes the whole input unsupported" do
      assert parse!("(a = 'x'::text) junk") == {:unsupported, "(a = 'x'::text) junk"}
      assert parse!("(a = 'x'::text) (b)") == {:unsupported, "(a = 'x'::text) (b)"}
      assert parse!("a b") == {:unsupported, "a b"}
      assert parse!("true false") == {:unsupported, "true false"}
    end

    test "trailing junk makes only the part it trails unsupported" do
      assert parse!("((a = 'x'::text) junk OR (b = 'y'::text))") ==
               {:bool_expr, :or, [{:unsupported, "(a = 'x'::text) junk"}, {:op, "=", col("b"), text("y")}]}

      assert parse!("((a = 'x'::text) AND (b = 'y'::text) junk)") ==
               {:bool_expr, :and, [{:op, "=", col("a"), text("x")}, {:unsupported, "(b = 'y'::text) junk"}]}

      assert parse!("(a = 'x'::text junk)") == {:op, "=", col("a"), {:unsupported, "'x'::text junk"}}
      assert parse!("(a junk = 'x'::text)") == {:op, "=", {:unsupported, "a junk"}, text("x")}
      assert parse!("(NOT a junk)") == {:not, {:unsupported, "a junk"}}
      assert parse!("COALESCE(a junk, b)") == {:coalesce, [{:unsupported, "a junk"}, col("b")]}
      assert parse!("(a junk IS NULL)") == {:null_test, :is_null, {:unsupported, "a junk"}}
    end

    test "text that isn't what Postgres prints is unsupported, so nothing is normalised on the way through" do
      for input <- [
            "('x')::text",
            "(NULL)::text",
            "(ARRAY[])::text[]",
            "ARRAY[a]::text[]",
            ~s|("foo" = 'x'::text)|,
            "(user = 'x'::text)",
            "(a  = 'x'::text)",
            "( a = 'x'::text)",
            "(a = 'x'::text )",
            "(a = 'x' ::text)",
            "(a= 'x'::text)",
            "((a) = 'x'::text)",
            "(a AND b OR c)",
            "(a AND)",
            "(a)",
            "COALESCE()",
            "NULLIF(a)",
            "NULLIF(a, b, c)",
            "f( a)",
            "f(a,b)",
            "f(a , b)",
            "(a = ANY (b) )",
            "(a IS  NULL)",
            "(a is null)",
            "(a and b)",
            "(a = 'x'::TEXT junk)",
            "'x'::",
            "'x'::text.",
            "1.",
            "1e5",
            "Foo",
            "m.x",
            "f(a).b"
          ] do
        ast = parse!(input)
        assert unsupported_nodes(ast) != [], "#{inspect(input)} parsed as #{inspect(ast)}"
      end
    end

    test "every cut-down and spoiled fixture expression parses without raising and prints back unchanged" do
      mutations = @expressions |> Enum.map(& &1.text) |> Enum.uniq() |> Enum.flat_map(&mutations/1)

      assert length(mutations) > 10_000

      for mutated <- mutations do
        assert Deparse.to_string(Parser.parse(mutated)) == mutated
      end
    end

    test "deep nesting parses and prints back" do
      for depth <- [1, 50, 400],
          {open, middle, close} <- [
            {"(NOT ", "a", ")"},
            {"(a = ", "b", ")"},
            {"( SELECT ", "a", ")"},
            {"(", "a", ")"},
            {"(", "m.x", ")"},
            {"( SELECT ", "m.x", ")"},
            {"(", "a", ""}
          ] do
        input = String.duplicate(open, depth) <> middle <> String.duplicate(close, depth)
        assert Deparse.to_string(Parser.parse(input)) == input
      end
    end
  end

  describe "size limit" do
    # (topic = '<filler>'::text) is 18 bytes plus the filler
    defp comparison(bytes), do: "(topic = '" <> String.duplicate("x", bytes - 18) <> "'::text)"

    defp any_list(count), do: "(topic = ANY (ARRAY[#{Enum.map_join(1..count, ", ", fn _ -> "'a'::text" end)}]))"

    test "an expression of 4096 bytes still parses" do
      input = comparison(4096)

      assert byte_size(input) == 4096
      assert parse!(input) == {:op, "=", col("topic"), text(String.duplicate("x", 4078))}
    end

    test "an expression of 4097 bytes is unsupported as a whole, and prints back unchanged" do
      input = comparison(4097)

      assert byte_size(input) == 4097
      assert Parser.parse(input) == {:unsupported, input}
      assert Deparse.to_string(Parser.parse(input)) == input
    end

    test "a long canonical list close to the limit still parses" do
      input = any_list(360)

      assert byte_size(input) in 3900..4096
      assert {:scalar_array_op, "=", :any, _lhs, {:array, elements}} = parse!(input)
      assert length(elements) == 360
      assert unsupported_nodes(parse!(input)) == []
    end

    test "a long list over the limit is unsupported" do
      input = any_list(400)

      assert byte_size(input) > 4096
      assert Parser.parse(input) == {:unsupported, input}
    end

    test "the size is counted in bytes, not characters" do
      input = "(topic = '" <> String.duplicate("é", 2040) <> "'::text)"

      assert String.length(input) < 4096
      assert byte_size(input) > 4096
      assert Parser.parse(input) == {:unsupported, input}
    end
  end

  describe "Deparse" do
    test "quotes identifiers the way Postgres does" do
      assert Deparse.to_string({:column, "topic"}) == "topic"
      assert Deparse.to_string({:column, "has space"}) == ~s("has space")
      assert Deparse.to_string({:column, "Upper"}) == ~s("Upper")
      assert Deparse.to_string({:column, "1abc"}) == ~s("1abc")
      assert Deparse.to_string({:column, ~s(a"b)}) == ~s("a""b")
      assert Deparse.to_string({:column, "user"}) == ~s("user")
      assert Deparse.to_string({:column, "event"}) == "event"
      assert Deparse.to_string({:func, "auth", "uid", []}) == "auth.uid()"
      assert Deparse.to_string({:func, "My Schema", "left", []}) == ~s|"My Schema"."left"()|
    end

    test "doubles quotes in string literals" do
      assert Deparse.to_string({:const, :string, "it's"}) == "'it''s'"
      assert Deparse.to_string({:cast, {:const, :string, "''"}, "text"}) == "''''''::text"
    end

    test "parenthesises a cast unless it is of a string, NULL or empty array" do
      assert Deparse.to_string({:cast, {:const, :string, "x"}, "text"}) == "'x'::text"
      assert Deparse.to_string({:cast, {:const, :null}, "text"}) == "NULL::text"
      assert Deparse.to_string({:cast, {:array, []}, "text[]"}) == "ARRAY[]::text[]"
      assert Deparse.to_string({:cast, number("1"), "double precision"}) == "(1)::double precision"
      assert Deparse.to_string({:cast, {:const, :bool, true}, "text"}) == "(true)::text"
      assert Deparse.to_string({:cast, {:cast, {:const, :string, "x"}, "text"}, "jsonb"}) == "('x'::text)::jsonb"
    end

    test "prints unsupported nodes as their raw text" do
      assert Deparse.to_string({:unsupported, "whatever\n  it was"}) == "whatever\n  it was"
      assert Deparse.to_string({:op, "=", {:unsupported, "x.y"}, {:unsupported, "z"}}) == "(x.y = z)"
    end
  end
end
