defmodule PolicyEval.ResolverTest do
  use ExUnit.Case, async: true

  alias PolicyEval.Jsonb
  alias PolicyEval.Resolver
  alias PolicyEval.Test.ExampleProfile
  alias PolicyEval.Value

  @profile ExampleProfile.profile()

  {catalog, _} = Code.eval_file(Path.expand("../fixtures/pg17/catalog.exs", __DIR__))
  @functions catalog.functions

  @uuid_text "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @uuid <<0xA0, 0xEE, 0xBC, 0x99, 0x9C, 0x0B, 0x4E, 0xF8, 0xBB, 0x6D, 0x6B, 0xB9, 0xBD, 0x38, 0x0A, 0x11>>

  # AST builders
  defp text(s), do: {:cast, {:const, :string, s}, "text"}
  defp null(type), do: {:cast, {:const, :null}, type}
  defp team, do: {:column, "team"}
  defp kind, do: {:column, "kind"}
  defp user_id, do: {:func, "app", "user_id", []}
  defp app_team, do: {:func, "app", "team", []}

  defp claims,
    do: {:cast, {:func, nil, "current_setting", [text("app.claims"), {:const, :bool, true}]}, "jsonb"}

  # IR builders
  defp call(module, function, args), do: {:apply, module, function, args}
  defp lit_text(s), do: {:lit, {:text, s}}
  defp unsupported(reason), do: {{:unsupported, reason}, :unknown}

  defp resolve(ast, functions \\ @functions), do: Resolver.resolve(ast, functions, @profile)

  describe "constants" do
    test "a boolean is a boolean literal" do
      assert resolve({:const, :bool, true}) == {{:lit, true}, :bool}
      assert resolve({:const, :bool, false}) == {{:lit, false}, :bool}
    end

    test "untyped strings, numbers and NULL are unsupported" do
      assert resolve({:const, :string, "x"}) == unsupported(:untyped_string_literal)
      assert resolve({:const, :number, "1"}) == unsupported(:number_literal)
      assert resolve({:const, :null}) == unsupported(:untyped_null)
    end

    test "text the parser couldn't read is unsupported, with its first keyword and nothing else" do
      assert resolve({:unsupported, "CASE WHEN x END"}) == unsupported({:unparsed, :case})
    end

    test "the keyword of unparsed text is the first word, ignoring case, parentheses and whitespace" do
      for {raw, keyword} <- [
            {"CASE\n WHEN a THEN b END", :case},
            {"(EXISTS ( SELECT 1\n   FROM t))", :exists},
            {"( SELECT count(*) AS count\n   FROM t)", :select},
            {"ARRAY[1, 2]", :array},
            {"ROW(a, b)", :row},
            {"NOT a", :not},
            {"exists (x)", :exists},
            {"((kind = 'x'::text) IS TRUE)", :other},
            {"CASEY WHEN", :other},
            {"case_x", :other},
            {~s("case" = 1), :other},
            {"m.team", :other},
            {"", :other}
          ] do
        assert resolve({:unsupported, raw}) == unsupported({:unparsed, keyword}), inspect(raw)
      end
    end

    test "unparsed text with a SELECT further in is a subquery" do
      # How Postgres 17 prints `team IN (SELECT l.team FROM public.lookup l)` with search_path = ''
      assert resolve({:unsupported, "(team IN ( SELECT l.team\n   FROM public.lookup l))"}) ==
               unsupported({:unparsed, :subquery})

      assert resolve({:unsupported, "(team ~~ 'selected%'::text)"}) == unsupported({:unparsed, :other})
    end

    test "an unknown node is unsupported rather than a crash, with its tag only" do
      assert resolve({:weird, 1}) == unsupported({:unknown_node, :weird})
      assert resolve({:weird, "customer text", {:nested, 2}}) == unsupported({:unknown_node, :weird})
      assert resolve({"weird"}) == unsupported({:unknown_node, :other})
      assert resolve({}) == unsupported({:unknown_node, :other})
      assert resolve(:weird) == unsupported({:unknown_node, :other})
    end
  end

  describe "columns" do
    test "team and kind are text columns" do
      assert resolve(team()) == {{:column, "team"}, :text}
      assert resolve(kind()) == {{:column, "kind"}, :text}
    end

    test "any other column is unsupported" do
      for name <- ["private", "event", "payload", "id", "Topic"] do
        assert resolve({:column, name}) == unsupported({:column, name})
      end
    end
  end

  describe "AND, OR and NOT" do
    test "AND and OR bind their children and are boolean" do
      ast = {:bool_expr, :and, [{:const, :bool, true}, {:op, "=", team(), text("a")}]}

      assert resolve(ast) ==
               {{:and, [{:lit, true}, call(Value, :text_eq, [{:column, "team"}, lit_text("a")])]}, :bool}

      assert {{:or, [{:lit, true}, {:lit, false}]}, :bool} =
               resolve({:bool_expr, :or, [{:const, :bool, true}, {:const, :bool, false}]})
    end

    test "a child that isn't boolean becomes unsupported in place" do
      assert resolve({:bool_expr, :and, [{:const, :bool, true}, team()]}) ==
               {{:and, [{:lit, true}, {:unsupported, {:not_boolean, :text}}]}, :bool}

      assert resolve({:bool_expr, :or, [user_id(), {:const, :bool, true}]}) ==
               {{:or, [{:unsupported, {:not_boolean, :uuid}}, {:lit, true}]}, :bool}
    end

    test "an unsupported child keeps its own reason" do
      assert resolve({:bool_expr, :and, [{:unsupported, "CASE x"}, {:const, :bool, true}]}) ==
               {{:and, [{:unsupported, {:unparsed, :case}}, {:lit, true}]}, :bool}
    end

    test "NOT binds a boolean" do
      assert resolve({:not, {:const, :bool, true}}) == {{:not, {:lit, true}}, :bool}
      assert resolve({:not, {:unsupported, "CASE x"}}) == {{:not, {:unsupported, {:unparsed, :case}}}, :bool}
    end

    test "NOT of a non-boolean is NOT of an unsupported" do
      assert resolve({:not, team()}) == {{:not, {:unsupported, {:not_boolean, :text}}}, :bool}
    end
  end

  describe "operators" do
    for {op, function} <- [{"=", :text_eq}, {"<>", :text_ne}] do
      test "#{op} on text with text is #{function}" do
        assert resolve({:op, unquote(op), team(), text("a")}) ==
                 {call(Value, unquote(function), [{:column, "team"}, lit_text("a")]), :bool}
      end
    end

    for {op, function} <- [{"=", :uuid_eq}, {"<>", :uuid_ne}] do
      test "#{op} on uuid with uuid is #{function}" do
        ast = {:op, unquote(op), user_id(), {:cast, {:const, :string, @uuid_text}, "uuid"}}

        assert {{:apply, Value, unquote(function), [_uid_body, {:lit, {:uuid, @uuid}}]}, :bool} = resolve(ast)
      end
    end

    test "|| on text with text is textcat, and on text with uuid is textanycat" do
      assert resolve({:op, "||", text("a"), text("b")}) ==
               {call(Value, :textcat, [lit_text("a"), lit_text("b")]), :text}

      assert {{:apply, Value, :textanycat, [{:lit, {:text, "user:"}}, {:apply, Value, :uuid_in, _}]}, :text} =
               resolve({:op, "||", text("user:"), user_id()})
    end

    test "~ and ~* on text with text are the regex primitive with the mode as a literal" do
      assert resolve({:op, "~", team(), text("a")}) ==
               {call(Value, :regex_match, [{:column, "team"}, lit_text("a"), {:lit, :case_sensitive}]), :bool}

      assert resolve({:op, "~*", team(), text("a")}) ==
               {call(Value, :regex_match, [{:column, "team"}, lit_text("a"), {:lit, :case_insensitive}]), :bool}
    end

    test "~~ on text with text is like, and !~~ is its negation" do
      assert resolve({:op, "~~", team(), text("a%")}) ==
               {call(Value, :like, [{:column, "team"}, lit_text("a%")]), :bool}

      assert resolve({:op, "!~~", team(), text("a%")}) ==
               {{:not, call(Value, :like, [{:column, "team"}, lit_text("a%")])}, :bool}
    end

    test "~~* and !~~* on text with text are unsupported, because ILIKE folds case by the collation" do
      for op <- ["~~*", "!~~*"] do
        assert resolve({:op, op, team(), text("a%")}) == unsupported({:operator, op, :text, :text})
      end
    end

    test "->> on jsonb with text is object_field_text" do
      assert resolve({:op, "->>", claims(), text("sub")}) ==
               {call(Jsonb, :object_field_text, [
                  call(Jsonb, :parse, [{:setting, "app.claims"}]),
                  lit_text("sub")
                ]), :text}
    end

    test "any other combination is unsupported" do
      for {op, left, right, types} <- [
            {"=", team(), user_id(), {:text, :uuid}},
            {"=", user_id(), team(), {:uuid, :text}},
            {"<>", claims(), claims(), {:jsonb, :jsonb}},
            {"=", {:const, :bool, true}, {:const, :bool, true}, {:bool, :bool}},
            {"||", user_id(), text("a"), {:uuid, :text}},
            {"||", claims(), text("a"), {:jsonb, :text}},
            {"~", user_id(), text("a"), {:uuid, :text}},
            {"->", claims(), text("a"), {:jsonb, :text}},
            {"->>", team(), text("a"), {:text, :text}},
            {"<", team(), text("a"), {:text, :text}},
            {"~~", user_id(), text("a"), {:uuid, :text}},
            {"!~~", team(), user_id(), {:text, :uuid}},
            {"!~", team(), text("a"), {:text, :text}}
          ] do
        {_, lt} = resolve(left)
        {_, rt} = resolve(right)
        assert {lt, rt} == types, inspect({op, left, right})

        assert resolve({:op, op, left, right}) == unsupported({:operator, op, lt, rt}), inspect({op, left, right})
      end
    end

    test "an operand that is unsupported makes the operator unsupported with that reason" do
      assert resolve({:op, "=", {:unsupported, "CASE x"}, text("a")}) == unsupported({:unparsed, :case})
      assert resolve({:op, "=", team(), {:column, "private"}}) == unsupported({:column, "private"})

      assert resolve({:op, "=", {:unsupported, "CASE x"}, {:unsupported, "EXISTS y"}}) ==
               unsupported({:unparsed, :case})
    end
  end

  describe "ANY and ALL over arrays" do
    defp array(elements), do: {:array, elements}

    test "text = ANY (ARRAY[...]) is text_eq_any over the element list" do
      assert resolve({:scalar_array_op, "=", :any, kind(), array([text("note"), text("task")])}) ==
               {call(Value, :text_eq_any, [
                  {:column, "kind"},
                  {:array, [lit_text("note"), lit_text("task")]}
                ]), :bool}
    end

    test "elements may be NULL, and the array may be empty" do
      assert resolve({:scalar_array_op, "=", :any, kind(), array([text("a"), null("text")])}) ==
               {call(Value, :text_eq_any, [{:column, "kind"}, {:array, [lit_text("a"), {:lit, nil}]}]), :bool}

      assert resolve({:scalar_array_op, "=", :any, kind(), {:cast, array([]), "text[]"}}) ==
               {call(Value, :text_eq_any, [{:column, "kind"}, {:array, []}]), :bool}
    end

    test "text <> ALL (ARRAY[...]) is NOT of the = ANY" do
      assert resolve({:scalar_array_op, "<>", :all, kind(), array([text("note"), text("task")])}) ==
               {{:not,
                 call(Value, :text_eq_any, [
                   {:column, "kind"},
                   {:array, [lit_text("note"), lit_text("task")]}
                 ])}, :bool}
    end

    test "other operators and quantifiers are unsupported" do
      for {op, quantifier} <- [{"<>", :any}, {"=", :all}, {"<", :any}, {"~", :any}, {"<", :all}] do
        assert resolve({:scalar_array_op, op, quantifier, kind(), array([text("a")])}) ==
                 unsupported({:array_operator, op, quantifier})
      end
    end

    test "a left side or elements that aren't text are unsupported" do
      uuid = {:cast, {:const, :string, @uuid_text}, "uuid"}

      assert resolve({:scalar_array_op, "=", :any, user_id(), array([text("a")])}) ==
               unsupported({:array_types, :uuid, [:text]})

      assert resolve({:scalar_array_op, "=", :any, kind(), array([text("a"), uuid])}) ==
               unsupported({:array_types, :text, [:text, :uuid]})

      assert resolve({:scalar_array_op, "<>", :all, kind(), array([uuid])}) ==
               unsupported({:array_types, :text, [:uuid]})
    end

    test "an unsupported left side or element makes it unsupported with that reason" do
      assert resolve({:scalar_array_op, "=", :any, {:unsupported, "CASE x"}, array([text("a")])}) ==
               unsupported({:unparsed, :case})

      assert resolve({:scalar_array_op, "=", :any, kind(), array([text("a"), {:unsupported, "EXISTS y"}])}) ==
               unsupported({:unparsed, :exists})

      assert resolve({:scalar_array_op, "<>", :all, kind(), array([{:unsupported, "EXISTS y"}])}) ==
               unsupported({:unparsed, :exists})
    end

    test "an array that isn't a constructor is unsupported" do
      assert resolve({:scalar_array_op, "=", :any, kind(), {:cast, {:const, :string, "{a}"}, "text[]"}}) ==
               unsupported(:array_not_constructor)

      assert resolve({:scalar_array_op, "=", :any, kind(), {:unsupported, "CASE x"}}) ==
               unsupported(:array_not_constructor)

      assert resolve({:array, [text("a")]}) == unsupported(:array_not_constructor)
    end
  end

  describe "NULL tests" do
    test "IS NULL and IS NOT NULL are the primitives" do
      assert resolve({:null_test, :is_null, team()}) == {call(Value, :is_null, [{:column, "team"}]), :bool}

      assert {{:apply, Value, :is_not_null, [{:apply, Value, :uuid_in, _}]}, :bool} =
               resolve({:null_test, :is_not_null, user_id()})
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

    test "to a type that the policy author created is unsupported without its name" do
      for type <- ["public.status", ~s(public."My Type"), "other.status[]"] do
        assert resolve({:cast, {:const, :string, "x"}, type}) == unsupported({:cast, :string_literal, :other_schema})
        assert resolve(null(type)) == unsupported({:cast, :null, :other_schema})
        assert resolve({:cast, team(), type}) == unsupported({:cast, :text, :other_schema})
      end

      assert resolve({:cast, team(), "app.level"}) == unsupported({:cast, :text, "app.level"})
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
      assert resolve({:cast, team(), "text"}) == {{:column, "team"}, :text}
    end

    test "uuid to text is uuid_out" do
      assert {{:apply, Value, :uuid_out, [{:apply, Value, :uuid_in, _}]}, :text} = resolve({:cast, user_id(), "text"})
    end

    test "text to uuid, jsonb and boolean" do
      assert resolve({:cast, team(), "uuid"}) == {call(Value, :uuid_in, [{:column, "team"}]), :uuid}
      assert resolve({:cast, team(), "jsonb"}) == {call(Jsonb, :parse, [{:column, "team"}]), :jsonb}
      assert resolve({:cast, team(), "boolean"}) == {call(Value, :bool_in, [{:column, "team"}]), :bool}
    end

    test "a NULL literal goes through the cast like any value" do
      assert resolve({:cast, null("text"), "uuid"}) == {call(Value, :uuid_in, [{:lit, nil}]), :uuid}
    end

    test "everything else is unsupported" do
      for {expr, from, to} <- [
            {claims(), :jsonb, "text"},
            {{:const, :bool, true}, :bool, "text"},
            {user_id(), :uuid, "uuid"},
            {user_id(), :uuid, "boolean"},
            {team(), :text, "character varying"},
            {team(), :text, "integer"},
            {claims(), :jsonb, "boolean"},
            {{:const, :bool, true}, :bool, "boolean"}
          ] do
        assert resolve({:cast, expr, to}) == unsupported({:cast, from, to}), inspect({expr, to})
      end
    end

    test "an unsupported operand makes the cast unsupported with that reason" do
      assert resolve({:cast, {:unsupported, "CASE x"}, "text"}) == unsupported({:unparsed, :case})
      assert resolve({:cast, {:column, "private"}, "boolean"}) == unsupported({:column, "private"})
    end
  end

  describe "known functions" do
    test "app.team() is inlined" do
      assert resolve(app_team()) ==
               {call(Value, :nullif, [{:setting, "app.team"}, lit_text("")]), :text}
    end

    test "app.user_id() is inlined with the type uuid, app.user_role() as text and app.claims() as jsonb" do
      assert {{:apply, Value, :uuid_in, _}, :uuid} = resolve(user_id())
      assert {{:apply, Value, :nullif, _}, :text} = resolve({:func, "app", "user_role", []})
      assert {{:apply, Jsonb, :parse, _}, :jsonb} = resolve({:func, "app", "claims", []})
    end

    test "a function absent from the snapshot is unsupported" do
      assert resolve(app_team(), []) == unsupported({:function, "app.team", :not_in_snapshot})
      assert resolve(user_id(), []) == unsupported({:function, "app.user_id", :not_in_snapshot})
      assert resolve({:func, "app", "email", []}) == unsupported({:function, "app.email", :not_in_snapshot})
    end

    test "a definition that isn't a known one is unsupported" do
      changed = Enum.map(@functions, &if(&1.name == "user_id", do: %{&1 | volatility: "v"}, else: &1))

      assert resolve(user_id(), changed) == unsupported({:function, "app.user_id", :unknown_definition})
      assert {_, :text} = resolve(app_team(), changed)
    end

    test "several definitions of the same name are unsupported" do
      [user_id_definition] = Enum.filter(@functions, &(&1.name == "user_id"))

      assert resolve(user_id(), [user_id_definition, user_id_definition]) ==
               unsupported({:function, "app.user_id", :overloaded})
    end

    test "a call with arguments, or another schema, is not allowlisted" do
      assert resolve({:func, "app", "user_id", [text("x")]}) ==
               unsupported({:function, "app.user_id", :not_allowlisted})

      assert resolve({:func, "public", "user_id", []}) == unsupported({:function, :other_schema, :not_allowlisted})
      assert resolve({:func, nil, "now", []}) == unsupported({:function, "now", :not_allowlisted})
      assert resolve({:func, nil, "user_id", []}) == unsupported({:function, "user_id", :not_allowlisted})

      assert resolve({:func, "public", "test_log_error", []}) ==
               unsupported({:function, :other_schema, :not_allowlisted})
    end
  end

  describe "current_setting" do
    test "with a literal name and missing_ok true is a setting" do
      assert resolve({:func, nil, "current_setting", [text("app.claims"), {:const, :bool, true}]}) ==
               {{:setting, "app.claims"}, :text}

      assert resolve({:func, nil, "current_setting", [text("App.Claims"), {:const, :bool, true}]}) ==
               {{:setting, "App.Claims"}, :text}
    end

    test "any other form is unsupported" do
      for args <- [
            [text("role"), {:const, :bool, false}],
            [text("role")],
            [team(), {:const, :bool, true}],
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
               unsupported({:function, :other_schema, :not_allowlisted})
    end
  end

  describe "COALESCE" do
    test "of arguments of one type has that type" do
      assert resolve({:coalesce, [app_team(), text("x")]}) ==
               {{:coalesce, [call(Value, :nullif, [{:setting, "app.team"}, lit_text("")]), lit_text("x")]}, :text}
    end

    test "a NULL literal has the type it is cast to" do
      assert resolve({:coalesce, [null("text"), text("x")]}) == {{:coalesce, [{:lit, nil}, lit_text("x")]}, :text}
    end

    test "arguments of different types are unsupported" do
      assert resolve({:coalesce, [team(), user_id()]}) == unsupported({:coalesce_types, [:text, :uuid]})
    end

    test "an unsupported argument makes it unsupported, wherever it is" do
      assert resolve({:coalesce, [team(), {:unsupported, "CASE x"}]}) == unsupported({:unparsed, :case})
      assert resolve({:coalesce, [{:unsupported, "CASE x"}, {:const, :bool, false}]}) == unsupported({:unparsed, :case})
    end

    test "with several unsupported arguments is unsupported, with the first reason" do
      assert resolve({:coalesce, [{:unsupported, "CASE x"}, {:unsupported, "EXISTS y"}]}) ==
               unsupported({:unparsed, :case})
    end

    test "an argument Postgres folds and raises on makes the comparison unsupported, even after a value" do
      # Postgres 17 folds ((1 / 0))::text while planning, so this raises even though team comes first
      ast = PolicyEval.Parser.parse("(COALESCE(app.team(), ((1 / 0))::text) = 'x'::text)")
      {ir, _type} = resolve(ast)
      env = PolicyEval.Env.new(%{"app.team" => "x"}, %{})

      assert {:unsupported, _reason} = PolicyEval.Eval.eval(ir, env)
    end
  end

  describe "NULLIF" do
    test "is bound for text only" do
      assert resolve({:nullif, app_team(), text("x")}) ==
               {call(Value, :nullif, [call(Value, :nullif, [{:setting, "app.team"}, lit_text("")]), lit_text("x")]),
                :text}

      assert resolve({:nullif, user_id(), user_id()}) == unsupported({:nullif, :uuid, :uuid})
      assert resolve({:nullif, team(), user_id()}) == unsupported({:nullif, :text, :uuid})
    end

    test "with an unsupported argument is unsupported with that reason" do
      assert resolve({:nullif, team(), {:unsupported, "CASE x"}}) == unsupported({:unparsed, :case})
    end
  end

  describe "scalar subselects" do
    test "( SELECT x) is x" do
      assert resolve({:sublink, user_id(), "uid"}) == resolve(user_id())

      assert resolve({:sublink, {:func, "public", "f", []}, nil}) ==
               unsupported({:function, :other_schema, :not_allowlisted})
    end
  end

  describe "the captured policies" do
    # Policies that resolve to IR with no unsupported node anywhere
    @supported [
      "lobby",
      "members read in their own team",
      "members read in their own team (initplan)",
      "members write in their own team",
      "members write in their own team (initplan)",
      "typical_member_read_all",
      "typical_member_insert_all",
      "typical_member_read_notes",
      "typical_member_read_notes_and_tasks",
      "typical_member_read_notes_by_claim",
      "typical_member_read_matching_user_id",
      "typical_member_read_tasks",
      "typical_member_read_tasks_by_claim",
      "typical_member_read_own_tasks",
      "typical_member_write_notes",
      "typical_member_write_notes_and_tasks",
      "typical_member_write_matching_user_id",
      "typical_member_write_files",
      "typical_member_write_tasks",
      "typical_read_matching_user_role",
      "typical_write_matching_user_role",
      "grammar_all_using_only",
      "grammar_and_in_or",
      "grammar_user_role",
      "grammar_setting_boolean",
      "grammar_setting_text",
      "grammar_coalesce",
      "grammar_concat_null",
      "grammar_doubled_quote",
      "grammar_eq_null",
      "grammar_false",
      "grammar_in_single",
      "grammar_is_not_null",
      "grammar_is_null",
      "grammar_claims_text",
      "grammar_claims_text_initplan",
      "grammar_neq",
      "grammar_not",
      "grammar_not_in",
      "grammar_not_in_single",
      "grammar_nullif",
      "grammar_or_in_and",
      "grammar_regex_case_sensitive",
      "grammar_restrictive",
      "grammar_to_guest_member",
      "grammar_to_public",
      "grammar_true"
    ]

    # Policies that stay unsupported in part: a subselect with FROM, CASE, EXISTS, a call to a
    # function we don't know, or a column of the row we don't model
    @partly_unsupported [
      "typical_broken_read",
      "typical_broken_write",
      "typical_slow_read",
      "typical_slow_write",
      "grammar_and_three",
      "grammar_case_searched",
      "grammar_case_simple",
      "grammar_title",
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
          {ir, type} = text |> PolicyEval.Parser.parse() |> Resolver.resolve(@catalog.functions, @profile)
          assert type in [:bool, :unknown], "#{policy.name}: #{inspect(type)}"
          assert type == :bool or match?({:unsupported, _}, ir), policy.name
        end
      end

      test "#{version}: the policies named in @supported resolve completely and the others are partly unsupported" do
        resolved =
          for policy <- @catalog.policies, text <- [policy.qual || policy.with_check] do
            {ir, _type} = text |> PolicyEval.Parser.parse() |> Resolver.resolve(@catalog.functions, @profile)
            {policy.name, contains_unsupported?(ir)}
          end

        assert resolved |> Enum.reject(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> Enum.sort() == Enum.sort(@supported)

        assert resolved |> Enum.filter(&elem(&1, 1)) |> Enum.map(&elem(&1, 0)) |> Enum.sort() ==
                 Enum.sort(@partly_unsupported)
      end
    end
  end
end
