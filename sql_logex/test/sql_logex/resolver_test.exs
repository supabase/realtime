defmodule SqlLogex.ResolverTest do
  use ExUnit.Case, async: true

  alias SqlLogex.Jsonb
  alias SqlLogex.Resolver
  alias SqlLogex.Value

  {catalog, _} = Code.eval_file(Path.expand("../fixtures/pg17/catalog.exs", __DIR__))
  @functions catalog.functions

  @uuid_text "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @uuid <<0xA0, 0xEE, 0xBC, 0x99, 0x9C, 0x0B, 0x4E, 0xF8, 0xBB, 0x6D, 0x6B, 0xB9, 0xBD, 0x38, 0x0A, 0x11>>

  # AST builders
  defp text(s), do: {:cast, {:const, :string, s}, "text"}
  defp null(type), do: {:cast, {:const, :null}, type}
  defp topic, do: {:column, "topic"}
  defp extension, do: {:column, "extension"}
  defp uid, do: {:func, "auth", "uid", []}
  defp realtime_topic, do: {:func, "realtime", "topic", []}

  defp claims,
    do: {:cast, {:func, nil, "current_setting", [text("request.jwt.claims"), {:const, :bool, true}]}, "jsonb"}

  # IR builders
  defp call(module, function, args), do: {:apply, module, function, args}
  defp lit_text(s), do: {:lit, {:text, s}}
  defp unsupported(reason), do: {{:unsupported, reason}, :unknown}

  defp resolve(ast, functions \\ @functions), do: Resolver.resolve(ast, functions)

  describe "constants" do
    test "a boolean is a boolean literal" do
      assert resolve({:const, :bool, true}) == {{:lit, true}, :bool}
      assert resolve({:const, :bool, false}) == {{:lit, false}, :bool}
    end

    test "untyped strings, numbers and NULL are unsupported" do
      assert resolve({:const, :string, "x"}) == unsupported(:untyped_string_literal)
      assert resolve({:const, :number, "1"}) == unsupported({:number_literal, "1"})
      assert resolve({:const, :null}) == unsupported(:untyped_null)
    end

    test "text the parser couldn't read is unsupported, with the raw text" do
      assert resolve({:unsupported, "CASE WHEN x END"}) == unsupported({:unparsed, "CASE WHEN x END"})
    end

    test "an unknown node is unsupported rather than a crash" do
      assert resolve({:weird, 1}) == unsupported({:unknown_node, {:weird, 1}})
    end
  end

  describe "columns" do
    test "topic and extension are text columns" do
      assert resolve(topic()) == {{:column, "topic"}, :text}
      assert resolve(extension()) == {{:column, "extension"}, :text}
    end

    test "any other column is unsupported" do
      for name <- ["private", "event", "payload", "id", "Topic"] do
        assert resolve({:column, name}) == unsupported({:column, name})
      end
    end
  end

  describe "AND, OR and NOT" do
    test "AND and OR bind their children and are boolean" do
      ast = {:bool_expr, :and, [{:const, :bool, true}, {:op, "=", topic(), text("a")}]}

      assert resolve(ast) ==
               {{:and, [{:lit, true}, call(Value, :text_eq, [{:column, "topic"}, lit_text("a")])]}, :bool}

      assert {{:or, [{:lit, true}, {:lit, false}]}, :bool} =
               resolve({:bool_expr, :or, [{:const, :bool, true}, {:const, :bool, false}]})
    end

    test "a child that isn't boolean becomes unsupported in place" do
      assert resolve({:bool_expr, :and, [{:const, :bool, true}, topic()]}) ==
               {{:and, [{:lit, true}, {:unsupported, {:not_boolean, :text}}]}, :bool}

      assert resolve({:bool_expr, :or, [uid(), {:const, :bool, true}]}) ==
               {{:or, [{:unsupported, {:not_boolean, :uuid}}, {:lit, true}]}, :bool}
    end

    test "an unsupported child keeps its own reason" do
      assert resolve({:bool_expr, :and, [{:unsupported, "x"}, {:const, :bool, true}]}) ==
               {{:and, [{:unsupported, {:unparsed, "x"}}, {:lit, true}]}, :bool}
    end

    test "NOT binds a boolean" do
      assert resolve({:not, {:const, :bool, true}}) == {{:not, {:lit, true}}, :bool}
      assert resolve({:not, {:unsupported, "x"}}) == {{:not, {:unsupported, {:unparsed, "x"}}}, :bool}
    end

    test "NOT of a non-boolean is NOT of an unsupported" do
      assert resolve({:not, topic()}) == {{:not, {:unsupported, {:not_boolean, :text}}}, :bool}
    end
  end

  describe "operators" do
    for {op, function} <- [{"=", :text_eq}, {"<>", :text_ne}] do
      test "#{op} on text with text is #{function}" do
        assert resolve({:op, unquote(op), topic(), text("a")}) ==
                 {call(Value, unquote(function), [{:column, "topic"}, lit_text("a")]), :bool}
      end
    end

    for {op, function} <- [{"=", :uuid_eq}, {"<>", :uuid_ne}] do
      test "#{op} on uuid with uuid is #{function}" do
        ast = {:op, unquote(op), uid(), {:cast, {:const, :string, @uuid_text}, "uuid"}}

        assert {{:apply, Value, unquote(function), [_uid_body, {:lit, {:uuid, @uuid}}]}, :bool} = resolve(ast)
      end
    end

    test "|| on text with text is textcat, and on text with uuid is textanycat" do
      assert resolve({:op, "||", text("a"), text("b")}) ==
               {call(Value, :textcat, [lit_text("a"), lit_text("b")]), :text}

      assert {{:apply, Value, :textanycat, [{:lit, {:text, "user:"}}, {:apply, Value, :uuid_in, _}]}, :text} =
               resolve({:op, "||", text("user:"), uid()})
    end

    test "~ and ~* on text with text are the regex primitive with the mode as a literal" do
      assert resolve({:op, "~", topic(), text("a")}) ==
               {call(Value, :regex_match, [{:column, "topic"}, lit_text("a"), {:lit, :case_sensitive}]), :bool}

      assert resolve({:op, "~*", topic(), text("a")}) ==
               {call(Value, :regex_match, [{:column, "topic"}, lit_text("a"), {:lit, :case_insensitive}]), :bool}
    end

    test "->> on jsonb with text is object_field_text" do
      assert resolve({:op, "->>", claims(), text("sub")}) ==
               {call(Jsonb, :object_field_text, [
                  call(Jsonb, :parse, [{:setting, "request.jwt.claims"}]),
                  lit_text("sub")
                ]), :text}
    end

    test "any other combination is unsupported" do
      for {op, left, right, types} <- [
            {"=", topic(), uid(), {:text, :uuid}},
            {"=", uid(), topic(), {:uuid, :text}},
            {"<>", claims(), claims(), {:jsonb, :jsonb}},
            {"=", {:const, :bool, true}, {:const, :bool, true}, {:bool, :bool}},
            {"||", uid(), text("a"), {:uuid, :text}},
            {"||", claims(), text("a"), {:jsonb, :text}},
            {"~", uid(), text("a"), {:uuid, :text}},
            {"->", claims(), text("a"), {:jsonb, :text}},
            {"->>", topic(), text("a"), {:text, :text}},
            {"<", topic(), text("a"), {:text, :text}},
            {"~~", topic(), text("a"), {:text, :text}},
            {"!~", topic(), text("a"), {:text, :text}}
          ] do
        {_, lt} = resolve(left)
        {_, rt} = resolve(right)
        assert {lt, rt} == types, inspect({op, left, right})

        assert resolve({:op, op, left, right}) == unsupported({:operator, op, lt, rt}), inspect({op, left, right})
      end
    end

    test "an operand that is unsupported makes the operator unsupported with that reason" do
      assert resolve({:op, "=", {:unsupported, "x"}, text("a")}) == unsupported({:unparsed, "x"})
      assert resolve({:op, "=", topic(), {:column, "private"}}) == unsupported({:column, "private"})

      assert resolve({:op, "=", {:unsupported, "x"}, {:unsupported, "y"}}) == unsupported({:unparsed, "x"})
    end
  end

  describe "ANY and ALL over arrays" do
    defp array(elements), do: {:array, elements}

    test "text = ANY (ARRAY[...]) is text_eq_any over the element list" do
      assert resolve({:scalar_array_op, "=", :any, extension(), array([text("broadcast"), text("presence")])}) ==
               {call(Value, :text_eq_any, [
                  {:column, "extension"},
                  {:array, [lit_text("broadcast"), lit_text("presence")]}
                ]), :bool}
    end

    test "elements may be NULL, and the array may be empty" do
      assert resolve({:scalar_array_op, "=", :any, extension(), array([text("a"), null("text")])}) ==
               {call(Value, :text_eq_any, [{:column, "extension"}, {:array, [lit_text("a"), {:lit, nil}]}]), :bool}

      assert resolve({:scalar_array_op, "=", :any, extension(), {:cast, array([]), "text[]"}}) ==
               {call(Value, :text_eq_any, [{:column, "extension"}, {:array, []}]), :bool}
    end

    test "text <> ALL (ARRAY[...]) is NOT of the = ANY" do
      assert resolve({:scalar_array_op, "<>", :all, extension(), array([text("broadcast"), text("presence")])}) ==
               {{:not,
                 call(Value, :text_eq_any, [
                   {:column, "extension"},
                   {:array, [lit_text("broadcast"), lit_text("presence")]}
                 ])}, :bool}
    end

    test "other operators and quantifiers are unsupported" do
      for {op, quantifier} <- [{"<>", :any}, {"=", :all}, {"<", :any}, {"~", :any}, {"<", :all}] do
        assert resolve({:scalar_array_op, op, quantifier, extension(), array([text("a")])}) ==
                 unsupported({:array_operator, op, quantifier})
      end
    end

    test "a left side or elements that aren't text are unsupported" do
      uuid = {:cast, {:const, :string, @uuid_text}, "uuid"}

      assert resolve({:scalar_array_op, "=", :any, uid(), array([text("a")])}) ==
               unsupported({:array_types, :uuid, [:text]})

      assert resolve({:scalar_array_op, "=", :any, extension(), array([text("a"), uuid])}) ==
               unsupported({:array_types, :text, [:text, :uuid]})

      assert resolve({:scalar_array_op, "<>", :all, extension(), array([uuid])}) ==
               unsupported({:array_types, :text, [:uuid]})
    end

    test "an unsupported left side or element makes it unsupported with that reason" do
      assert resolve({:scalar_array_op, "=", :any, {:unsupported, "x"}, array([text("a")])}) ==
               unsupported({:unparsed, "x"})

      assert resolve({:scalar_array_op, "=", :any, extension(), array([text("a"), {:unsupported, "y"}])}) ==
               unsupported({:unparsed, "y"})

      assert resolve({:scalar_array_op, "<>", :all, extension(), array([{:unsupported, "y"}])}) ==
               unsupported({:unparsed, "y"})
    end

    test "an array that isn't a constructor is unsupported" do
      assert resolve({:scalar_array_op, "=", :any, extension(), {:cast, {:const, :string, "{a}"}, "text[]"}}) ==
               unsupported(:array_not_constructor)

      assert resolve({:scalar_array_op, "=", :any, extension(), {:unsupported, "x"}}) ==
               unsupported(:array_not_constructor)

      assert resolve({:array, [text("a")]}) == unsupported(:array_not_constructor)
    end
  end

  describe "NULL tests" do
    test "IS NULL and IS NOT NULL are the primitives" do
      assert resolve({:null_test, :is_null, topic()}) == {call(Value, :is_null, [{:column, "topic"}]), :bool}

      assert {{:apply, Value, :is_not_null, [{:apply, Value, :uuid_in, _}]}, :bool} =
               resolve({:null_test, :is_not_null, uid()})
    end

    test "an unsupported operand makes it unsupported" do
      assert resolve({:null_test, :is_null, {:column, "private"}}) == unsupported({:column, "private"})
    end
  end

  describe "casts of literals" do
    test "to text" do
      assert resolve(text("a")) == {lit_text("a"), :text}
      assert resolve(text("")) == {lit_text(""), :text}
    end

    test "to uuid, parsed now" do
      assert resolve({:cast, {:const, :string, @uuid_text}, "uuid"}) == {{:lit, {:uuid, @uuid}}, :uuid}
      assert resolve({:cast, {:const, :string, String.upcase(@uuid_text)}, "uuid"}) == {{:lit, {:uuid, @uuid}}, :uuid}
    end

    test "to jsonb, parsed now" do
      assert resolve({:cast, {:const, :string, ~s({"a":"b"})}, "jsonb"}) == {{:lit, {:jsonb, %{"a" => "b"}}}, :jsonb}
    end

    test "to boolean, parsed now" do
      assert resolve({:cast, {:const, :string, "true"}, "boolean"}) == {{:lit, true}, :bool}
      assert resolve({:cast, {:const, :string, "off"}, "boolean"}) == {{:lit, false}, :bool}
    end

    test "a literal Postgres raises on stays unsupported, with the reason" do
      assert resolve({:cast, {:const, :string, "nope"}, "uuid"}) ==
               unsupported({:raises, :invalid_text_representation, "invalid input syntax for type uuid"})

      assert resolve({:cast, {:const, :string, "{"}, "jsonb"}) ==
               unsupported({:raises, :invalid_text_representation, "invalid input syntax for type json"})

      assert resolve({:cast, {:const, :string, "maybe"}, "boolean"}) ==
               unsupported({:raises, :invalid_text_representation, "invalid input syntax for type boolean"})
    end

    test "to any other type is unsupported" do
      for type <- ["integer", "date", "character varying", "text[]", "bytea", "bool"] do
        assert resolve({:cast, {:const, :string, "1"}, type}) == unsupported({:cast, :string_literal, type})
      end
    end

    test "NULL cast to the four types is a typed NULL literal" do
      assert resolve(null("text")) == {{:lit, nil}, :text}
      assert resolve(null("uuid")) == {{:lit, nil}, :uuid}
      assert resolve(null("jsonb")) == {{:lit, nil}, :jsonb}
      assert resolve(null("boolean")) == {{:lit, nil}, :bool}
    end

    test "NULL cast to another type is unsupported" do
      assert resolve(null("integer")) == unsupported({:cast, :null, "integer"})
    end
  end

  describe "casts of expressions" do
    test "text to text is the identity" do
      assert resolve({:cast, topic(), "text"}) == {{:column, "topic"}, :text}
    end

    test "uuid to text is uuid_out" do
      assert {{:apply, Value, :uuid_out, [{:apply, Value, :uuid_in, _}]}, :text} = resolve({:cast, uid(), "text"})
    end

    test "text to uuid, jsonb and boolean" do
      assert resolve({:cast, topic(), "uuid"}) == {call(Value, :uuid_in, [{:column, "topic"}]), :uuid}
      assert resolve({:cast, topic(), "jsonb"}) == {call(Jsonb, :parse, [{:column, "topic"}]), :jsonb}
      assert resolve({:cast, topic(), "boolean"}) == {call(Value, :bool_in, [{:column, "topic"}]), :bool}
    end

    test "a NULL literal goes through the cast like any value" do
      assert resolve({:cast, null("text"), "uuid"}) == {call(Value, :uuid_in, [{:lit, nil}]), :uuid}
    end

    test "everything else is unsupported" do
      for {expr, from, to} <- [
            {claims(), :jsonb, "text"},
            {{:const, :bool, true}, :bool, "text"},
            {uid(), :uuid, "uuid"},
            {uid(), :uuid, "boolean"},
            {topic(), :text, "character varying"},
            {topic(), :text, "integer"},
            {claims(), :jsonb, "boolean"},
            {{:const, :bool, true}, :bool, "boolean"}
          ] do
        assert resolve({:cast, expr, to}) == unsupported({:cast, from, to}), inspect({expr, to})
      end
    end

    test "an unsupported operand makes the cast unsupported with that reason" do
      assert resolve({:cast, {:unsupported, "x"}, "text"}) == unsupported({:unparsed, "x"})
      assert resolve({:cast, {:column, "private"}, "boolean"}) == unsupported({:column, "private"})
    end
  end

  describe "known functions" do
    test "realtime.topic() is inlined" do
      assert resolve(realtime_topic()) ==
               {call(Value, :nullif, [{:setting, "realtime.topic"}, lit_text("")]), :text}
    end

    test "auth.uid() is inlined with the type uuid, auth.role() as text and auth.jwt() as jsonb" do
      assert {{:apply, Value, :uuid_in, _}, :uuid} = resolve(uid())
      assert {{:apply, Value, :nullif, _}, :text} = resolve({:func, "auth", "role", []})
      assert {{:apply, Jsonb, :parse, _}, :jsonb} = resolve({:func, "auth", "jwt", []})
    end

    test "a function absent from the snapshot is unsupported" do
      assert resolve(realtime_topic(), []) == unsupported({:function, "realtime.topic", :not_in_snapshot})
      assert resolve(uid(), []) == unsupported({:function, "auth.uid", :not_in_snapshot})
      assert resolve({:func, "auth", "email", []}) == unsupported({:function, "auth.email", :not_in_snapshot})
    end

    test "a definition that isn't a known one is unsupported" do
      changed = Enum.map(@functions, &if(&1.name == "uid", do: %{&1 | volatility: "v"}, else: &1))

      assert resolve(uid(), changed) == unsupported({:function, "auth.uid", :unknown_definition})
      assert {_, :text} = resolve(realtime_topic(), changed)
    end

    test "several definitions of the same name are unsupported" do
      [uid_definition] = Enum.filter(@functions, &(&1.name == "uid"))

      assert resolve(uid(), [uid_definition, uid_definition]) == unsupported({:function, "auth.uid", :overloaded})
    end

    test "a call with arguments, or another schema, is not allowlisted" do
      assert resolve({:func, "auth", "uid", [text("x")]}) == unsupported({:function, "auth.uid", :not_allowlisted})
      assert resolve({:func, "public", "uid", []}) == unsupported({:function, "public.uid", :not_allowlisted})
      assert resolve({:func, nil, "now", []}) == unsupported({:function, "now", :not_allowlisted})
      assert resolve({:func, nil, "uid", []}) == unsupported({:function, "uid", :not_allowlisted})

      assert resolve({:func, "public", "test_log_error", []}) ==
               unsupported({:function, "public.test_log_error", :not_allowlisted})
    end
  end

  describe "current_setting" do
    test "with a literal name and missing_ok true is a setting" do
      assert resolve({:func, nil, "current_setting", [text("request.jwt.claims"), {:const, :bool, true}]}) ==
               {{:setting, "request.jwt.claims"}, :text}

      assert resolve({:func, nil, "current_setting", [text("Request.JWT.Claims"), {:const, :bool, true}]}) ==
               {{:setting, "Request.JWT.Claims"}, :text}
    end

    test "any other form is unsupported" do
      for args <- [
            [text("role"), {:const, :bool, false}],
            [text("role")],
            [topic(), {:const, :bool, true}],
            [{:const, :string, "role"}, {:const, :bool, true}],
            [text("role"), {:cast, {:const, :string, "true"}, "boolean"}],
            [text("role"), {:const, :bool, true}, {:const, :bool, true}]
          ] do
        assert {{:unsupported, {:function, "current_setting", :not_allowlisted}}, :unknown} =
                 resolve({:func, nil, "current_setting", args})
      end
    end

    test "in another schema it is not allowlisted" do
      assert resolve({:func, "public", "current_setting", [text("role"), {:const, :bool, true}]}) ==
               unsupported({:function, "public.current_setting", :not_allowlisted})
    end
  end

  describe "COALESCE" do
    test "of arguments of one type has that type" do
      assert resolve({:coalesce, [realtime_topic(), text("x")]}) ==
               {{:coalesce, [call(Value, :nullif, [{:setting, "realtime.topic"}, lit_text("")]), lit_text("x")]}, :text}
    end

    test "a NULL literal has the type it is cast to" do
      assert resolve({:coalesce, [null("text"), text("x")]}) == {{:coalesce, [{:lit, nil}, lit_text("x")]}, :text}
    end

    test "arguments of different types are unsupported" do
      assert resolve({:coalesce, [topic(), uid()]}) == unsupported({:coalesce_types, [:text, :uuid]})
    end

    test "an unsupported argument makes it unsupported, wherever it is" do
      assert resolve({:coalesce, [topic(), {:unsupported, "x"}]}) == unsupported({:unparsed, "x"})
      assert resolve({:coalesce, [{:unsupported, "x"}, {:const, :bool, false}]}) == unsupported({:unparsed, "x"})
    end

    test "with several unsupported arguments is unsupported, with the first reason" do
      assert resolve({:coalesce, [{:unsupported, "x"}, {:unsupported, "y"}]}) == unsupported({:unparsed, "x"})
    end

    test "an argument Postgres folds and raises on makes the comparison unsupported, even after a value" do
      # Postgres 17 folds ((1 / 0))::text while planning, so this raises even though topic comes first
      ast = SqlLogex.Parser.parse("(COALESCE(realtime.topic(), ((1 / 0))::text) = 'x'::text)")
      {ir, _type} = resolve(ast)
      env = SqlLogex.Env.new(%{"realtime.topic" => "x"}, %{})

      assert {:unsupported, _reason} = SqlLogex.Eval.eval(ir, env)
    end
  end

  describe "NULLIF" do
    test "is bound for text only" do
      assert resolve({:nullif, realtime_topic(), text("x")}) ==
               {call(Value, :nullif, [call(Value, :nullif, [{:setting, "realtime.topic"}, lit_text("")]), lit_text("x")]),
                :text}

      assert resolve({:nullif, uid(), uid()}) == unsupported({:nullif, :uuid, :uuid})
      assert resolve({:nullif, topic(), uid()}) == unsupported({:nullif, :text, :uuid})
    end

    test "with an unsupported argument is unsupported with that reason" do
      assert resolve({:nullif, topic(), {:unsupported, "x"}}) == unsupported({:unparsed, "x"})
    end
  end

  describe "scalar subselects" do
    test "( SELECT x) is x" do
      assert resolve({:sublink, uid(), "uid"}) == resolve(uid())

      assert resolve({:sublink, {:func, "public", "f", []}, nil}) ==
               unsupported({:function, "public.f", :not_allowlisted})
    end
  end

  describe "the captured policies" do
    # Policies that resolve to IR with no unsupported node anywhere
    @supported [
      "lobby",
      "users receive on own channel",
      "users receive on own channel (initplan)",
      "users send on own channel",
      "users send on own channel (initplan)",
      "generator_authenticated_all_topic_read",
      "generator_authenticated_all_topic_insert",
      "generator_authenticated_read_broadcast",
      "generator_authenticated_read_broadcast_and_presence",
      "generator_authenticated_read_broadcast_based_on_claim",
      "generator_authenticated_read_matching_user_sub",
      "generator_authenticated_read_presence",
      "generator_authenticated_read_presence_based_on_claim",
      "generator_authenticated_read_presence_for_sub",
      "generator_authenticated_write_broadcast",
      "generator_authenticated_write_broadcast_and_presence",
      "generator_authenticated_write_matching_user_sub",
      "generator_authenticated_write_persistence",
      "generator_authenticated_write_presence",
      "generator_read_matching_user_role",
      "generator_write_matching_user_role",
      "grammar_all_using_only",
      "grammar_and_in_or",
      "grammar_auth_role",
      "grammar_claims_boolean",
      "grammar_claims_text",
      "grammar_coalesce",
      "grammar_concat_null",
      "grammar_doubled_quote",
      "grammar_eq_null",
      "grammar_false",
      "grammar_in_single",
      "grammar_is_not_null",
      "grammar_is_null",
      "grammar_jwt_text",
      "grammar_jwt_text_initplan",
      "grammar_neq",
      "grammar_not",
      "grammar_not_in",
      "grammar_not_in_single",
      "grammar_nullif",
      "grammar_or_in_and",
      "grammar_regex_case_sensitive",
      "grammar_restrictive",
      "grammar_to_anon_authenticated",
      "grammar_to_public",
      "grammar_true"
    ]

    # Policies that stay unsupported in part: a subselect with FROM, CASE, EXISTS, a call to a
    # function we don't know, or a column of the row we don't model
    @partly_unsupported [
      "generator_broken_read_presence",
      "generator_broken_write_presence",
      "generator_slow_read",
      "generator_slow_write",
      "grammar_and_three",
      "grammar_case_searched",
      "grammar_case_simple",
      "grammar_event",
      "grammar_exists",
      "grammar_private"
    ]

    defp contains_unsupported?({:unsupported, _}), do: true
    defp contains_unsupported?(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> contains_unsupported?()
    defp contains_unsupported?(list) when is_list(list), do: Enum.any?(list, &contains_unsupported?/1)
    defp contains_unsupported?(_other), do: false

    for version <- ["pg17", "pg15"] do
      {catalog, _} = Code.eval_file(Path.expand("../fixtures/#{version}/catalog.exs", __DIR__))
      @catalog catalog

      test "#{version}: every expression resolves, to a boolean or to an unsupported node" do
        for policy <- @catalog.policies, text <- [policy.qual, policy.with_check], text != nil do
          {ir, type} = text |> SqlLogex.Parser.parse() |> Resolver.resolve(@catalog.functions)
          assert type in [:bool, :unknown], "#{policy.name}: #{inspect(type)}"
          assert type == :bool or match?({:unsupported, _}, ir), policy.name
        end
      end

      test "#{version}: the policies named in @supported resolve completely and the others are partly unsupported" do
        resolved =
          for policy <- @catalog.policies, text <- [policy.qual || policy.with_check] do
            {ir, _type} = text |> SqlLogex.Parser.parse() |> Resolver.resolve(@catalog.functions)
            {policy.name, contains_unsupported?(ir)}
          end

        assert resolved |> Enum.reject(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.sort(@supported)

        assert resolved |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
                 Enum.sort(@partly_unsupported)
      end
    end
  end
end
