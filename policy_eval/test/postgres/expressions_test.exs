defmodule PolicyEval.Postgres.ExpressionsTest do
  # Level 1 of the differential tests: the evaluator gives the value that Postgres gives, for
  # single expressions, or falls back when it cannot be sure. Postgres is the oracle. Every case
  # runs through both, and PolicyEval.Differential compares the answers.
  #
  #   mix test test/postgres/expressions_test.exs
  #   POLICY_EVAL_REPORT=1 mix test test/postgres/expressions_test.exs   # coverage report
  #
  # A policy is created with the expression as a policy author writes it, and `pg_get_expr` is read
  # back: that is the text that the library gets. Postgres runs the deparsed text in a SELECT,
  # against a row of a table, with the settings of the case. The evaluator parses and evaluates the
  # same text. Each case runs in a transaction that rolls back.
  use ExUnit.Case, async: false

  alias PolicyEval.Differential
  alias PolicyEval.Eval
  alias PolicyEval.Parser
  alias PolicyEval.Resolver
  alias PolicyEval.Test.Collector
  alias PolicyEval.Test.Postgres
  alias PolicyEval.Test.ExampleDatabase
  alias PolicyEval.Test.ExampleProfile
  alias PolicyEval.Test.ExampleScenarios

  @moduletag :postgres
  @moduletag timeout: 600_000

  @profile ExampleProfile.profile()

  @own "c0ffee00-1111-4222-8333-444455556666"
  @other "deadbeef-0000-4000-8000-000000000001"

  # Strings that stand for a user id, the ways Postgres's uuid_in reads them, and the ways it doesn't
  @user_ids [
    {"canonical", @own},
    {"upper case", String.upcase(@own)},
    {"mixed case", "C0ffEE00-1111-4222-8333-444455556666"},
    {"braced", "{" <> @own <> "}"},
    {"braced, upper case", "{" <> String.upcase(@own) <> "}"},
    {"unhyphenated", String.replace(@own, "-", "")},
    {"hyphens after every group", "c0ff-ee00-1111-4222-8333-4444-5555-6666"},
    {"braced without hyphens", "{" <> String.replace(@own, "-", "") <> "}"},
    {"all zeros", "00000000-0000-0000-0000-000000000000"},
    {"empty", ""},
    {"missing", nil},
    {"not a uuid", "user_2abc"},
    {"too short", String.slice(@own, 0..-2//1)},
    {"too long", @own <> "0"},
    {"leading space", " " <> @own},
    {"trailing space", @own <> " "},
    {"trailing newline", @own <> "\n"},
    {"non-hex digit", "g0ffee00-1111-4222-8333-444455556666"},
    {"misplaced hyphen", "c0ffee001-111-4222-8333-444455556666"},
    {"double hyphen", "c0ffee00--1111-4222-8333-444455556666"},
    {"unclosed brace", "{" <> @own},
    {"unopened brace", @own <> "}"},
    {"fullwidth digit", "０0ffee00-1111-4222-8333-444455556666"},
    {"another uuid", @other}
  ]

  @groups [:three_valued, :text_and_arrays, :user_id_and_role, :claims, :regex, :literals]

  setup_all do
    %{collector: Collector.start(:expressions)}
  end

  setup do
    %{conn: start_supervised!(Postgres)}
  end

  for group <- @groups do
    test "expressions: #{group}", %{conn: conn, collector: collector} do
      functions = %{
        simple: load_functions(conn, :simple),
        fallback: load_functions(conn, :fallback)
      }

      results = Enum.map(cases(unquote(group)), &run_case(conn, functions, unquote(group), &1))

      Collector.finish(collector, results)
    end
  end

  ## The runner

  # The definitions of the functions of the profile in the database, with the bodies of a flavor.
  # The simple bodies of app.user_id() and app.user_role() read only their setting. The fallback
  # bodies also read the claims.
  defp load_functions(conn, flavor) do
    Postgres.rolled_back(conn, fn conn ->
      prepare_functions!(conn, flavor)
      Postgres.read_functions(conn, @profile)
    end)
  end

  defp prepare_functions!(_conn, :simple), do: :ok

  defp prepare_functions!(conn, :fallback),
    do: Postgrex.query!(conn, ExampleDatabase.fallback_functions_statement(), [])

  defp run_case(conn, functions, group, kase) do
    {deparsed, pg} =
      Postgres.rolled_back(conn, fn conn ->
        prepare_functions!(conn, kase.functions)
        Postgrex.query!(conn, "SET LOCAL search_path = ''", [])
        deparsed = create_policy_and_read_back!(conn, kase)
        {deparsed, postgres_value(conn, deparsed, kase.env)}
      end)

    ex = evaluate(deparsed, kase.env, functions[kase.functions])

    detail = """
      sql:       #{kase.sql}
      deparsed:  #{deparsed}
      functions: #{kase.functions}
      env:
    #{ExampleScenarios.describe_env(kase.env, kase.env.kind)}
    """

    Differential.compare(pg, ex, name: kase.name, group: group, detail: detail)
  end

  defp create_policy_and_read_back!(conn, kase) do
    create_policy = "CREATE POLICY tmp ON app.docs FOR SELECT TO member USING (#{kase.sql})"

    case Postgrex.query(conn, create_policy, []) do
      {:ok, _result} -> :ok
      {:error, error} -> raise "#{inspect(kase.name)}: #{Exception.message(error)}\nwhile running:\n#{create_policy}"
    end

    %{rows: [[deparsed]]} =
      Postgrex.query!(
        conn,
        "SELECT pg_get_expr(polqual, polrelid) FROM pg_policy WHERE polrelid = 'app.docs'::regclass AND polname = 'tmp'",
        []
      )

    deparsed
  end

  # What Postgres evaluates the deparsed text to, with the settings and the row of the case
  defp postgres_value(conn, deparsed, env) do
    # The row is in a table. As a VALUES list with parameters it would be a constant for the planner,
    # which folds what a constant allows: NULLIF(NULL, <raises>) is NULL there, and raises on a column.
    # A policy is evaluated against a column of the table
    Postgrex.query!(conn, "CREATE TEMP TABLE m AS SELECT $1::text AS team, $2::text AS kind", [
      env.row_team,
      env.kind
    ])

    Postgrex.query!(conn, "GRANT SELECT ON m TO PUBLIC", [])
    ExampleScenarios.set_settings!(conn, env)

    case Postgrex.query(conn, "SELECT #{deparsed} FROM pg_temp.m", []) do
      {:ok, %Postgrex.Result{rows: [[value]]}} -> {:ok, value}
      {:error, %Postgrex.Error{} = error} -> Postgres.error(error)
    end
  end

  defp evaluate(deparsed, env, functions) do
    {ir, _type} = deparsed |> Parser.parse() |> Resolver.resolve(functions, @profile)

    case Eval.eval(ir, ExampleScenarios.policy_eval_env(env, env.kind)) do
      {:unsupported, reason} -> {:unsupported, reason}
      value -> {:value, value}
    end
  rescue
    exception -> {:crash, Exception.format(:error, exception, __STACKTRACE__)}
  end

  ## The cases

  # An expression as a policy author writes it, the environment it is run in, and the bodies of
  # app.user_id() and app.user_role() in the database
  defp expression_case(sql, env_opts \\ [], opts \\ []) do
    functions = Keyword.get(opts, :functions, :simple)
    env_summary = if env_opts == [], do: "", else: " with #{inspect(env_opts, limit: 8, printable_limit: 60)}"
    functions_summary = if functions == :simple, do: "", else: " (#{functions} functions)"

    %{
      name: sql <> env_summary <> functions_summary,
      sql: sql,
      env: ExampleScenarios.env(env_opts),
      functions: functions
    }
  end

  defp lit(string), do: "'" <> String.replace(string, "'", "''") <> "'"

  defp cases(:three_valued) do
    constants =
      for(a <- ~w(true false NULL), b <- ~w(true false NULL), op <- ~w(AND OR), do: expression_case("#{a} #{op} #{b}")) ++
        for(a <- ~w(true false NULL), do: expression_case("NOT #{a}"))

    # A is true, false or NULL by the team, B by the kind
    expressions = [
      "app.team() = 'a' AND kind = 'x'",
      "app.team() = 'a' OR kind = 'x'",
      "NOT (app.team() = 'a')",
      "NOT (app.team() = 'a' AND kind = 'x')",
      "NOT (app.team() = 'a' OR kind = 'x')",
      "NOT (app.team() = 'a') OR kind = 'x'",
      "NOT (app.team() = 'a') AND NOT (kind = 'x')",
      "app.team() = 'a' AND (kind = 'x' OR NOT (app.team() = 'a'))",
      "(app.team() = 'a' OR kind = 'x') AND app.team() <> 'b'",
      "app.team() = 'a' AND kind = 'x' AND app.team() <> 'b'",
      "app.team() = 'a' OR kind = 'x' OR app.team() = 'b'",
      "(app.team() = 'a') IS NULL",
      "(app.team() = 'a' AND kind = 'x') IS NOT NULL",
      "NOT (kind IS NULL) AND app.team() IS NOT NULL",
      # Where one side is something we don't evaluate, and the other may decide
      "app.team() = 'a' OR lower(kind) = 'x'",
      "app.team() = 'a' AND lower(kind) = 'x'",
      "lower(kind) = 'x' OR app.team() = 'a'",
      "lower(kind) = 'x' AND app.team() = 'a'",
      "NOT (lower(kind) = 'x')",
      "NOT (lower(kind) = 'x' AND app.team() = 'a')"
    ]

    sources =
      for expression <- expressions, team <- ["a", "b", nil], kind <- ["x", "y", nil] do
        expression_case(expression, team: team, kind: kind)
      end

    constants ++ sources
  end

  defp cases(:text_and_arrays) do
    concat =
      for sql <- [
            "app.team() = 'x' || NULL",
            "app.team() = 'a' || NULL",
            "('x' || app.team()) = 'xa'",
            "('x' || app.team()) IS NULL",
            "app.team() || kind = 'ab'",
            "(app.team() || kind) IS NULL",
            "coalesce(app.team() || kind, 'none') = 'none'",
            "'a' || 'b' = 'ab'",
            "app.team() = 'a' || 'b'",
            "kind || '' = ''",
            "'' || kind = kind",
            "'x' || NULL IS NULL",
            "NOT ('x' || NULL IS NULL)",
            "app.team() <> 'x' || kind"
          ],
          team <- ["a", "ab", "", nil],
          kind <- ["b", nil] do
        expression_case(sql, team: team, kind: kind)
      end

    equality =
      for sql <- [
            "app.team() = 'x'",
            "app.team() <> 'x'",
            "kind = 'x'",
            "app.team() = kind",
            "'x' = app.team()",
            "app.team() IN ('x')",
            "app.team() NOT IN ('x')",
            "app.team() = ''",
            "app.team() <> ''"
          ],
          team <- [
            "x",
            "X",
            "x ",
            " x",
            "",
            nil,
            "é",
            "é",
            " ",
            "x\ny",
            "it's",
            "a\\b",
            "日本",
            "😀",
            "x\t"
          ] do
        expression_case(sql, team: team, kind: "x")
      end

    # Also against the NFC and NFD spelling of é
    unicode =
      for team <- ["é", "é"], literal <- ["é", "é"] do
        expression_case("app.team() = #{lit(literal)}", team: team)
      end

    any =
      for sql <- [
            "kind IN ('a', 'b')",
            "kind IN ('a', NULL)",
            "kind IN ('a', 'b', NULL)",
            "kind NOT IN ('a', 'b')",
            "kind NOT IN ('a', NULL)",
            "kind IN ('a')",
            "kind NOT IN ('a')",
            "NOT (kind IN ('a', 'b'))",
            "NOT (kind NOT IN ('a', 'b'))",
            "kind = ANY ('{}'::text[])",
            "kind = ANY (ARRAY[]::text[])",
            "kind <> ALL ('{}'::text[])",
            "kind <> ALL (ARRAY[]::text[])",
            "kind = ANY (ARRAY['a', 'b'])",
            "kind = ANY (ARRAY['a', NULL])",
            "kind <> ALL (ARRAY['a', NULL])",
            "kind = ANY ('{a,b}'::text[])",
            "kind = ANY ('{a,NULL}'::text[])",
            "kind = ANY (ARRAY[app.team(), 'z'])",
            "app.team() IN (kind, 'z')",
            "app.team() NOT IN (kind, 'z')",
            "kind IN ('a', 'b') AND kind NOT IN ('b')",
            "(kind IN ('a', NULL)) IS NULL",
            "NOT (kind = ANY ('{}'::text[]))"
          ],
          kind <- ["a", "b", "c", nil],
          team <- ["a", "z", nil] do
        expression_case(sql, team: team, kind: kind)
      end

    null_tests =
      for sql <- [
            "kind IS NULL",
            "kind IS NOT NULL",
            "app.team() IS NULL",
            "app.team() IS NOT NULL",
            "NOT (app.team() IS NULL)",
            "(kind = 'a') IS NULL",
            "(kind = 'a') IS NOT NULL",
            "app.team() IS NULL OR kind IS NULL",
            "app.team() IS NOT NULL AND kind IS NOT NULL"
          ],
          team <- ["a", "", nil],
          kind <- ["a", nil] do
        expression_case(sql, team: team, kind: kind)
      end

    coalesce_and_nullif =
      for sql <- [
            "coalesce(app.team(), 'x') = 'x'",
            "coalesce(app.team(), kind, 'z') = 'z'",
            "coalesce(NULL::text, kind) = 'a'",
            "coalesce(kind = 'a', false)",
            "coalesce(kind = 'a', true)",
            "coalesce(kind = 'a', app.team() = 'a')",
            "coalesce(NULL::boolean, NULL::boolean) IS NULL",
            "nullif(app.team(), 'x') = 'y'",
            "nullif(app.team(), 'x') IS NULL",
            "nullif(kind, app.team()) IS NULL",
            "nullif(kind, app.team()) = kind",
            "coalesce(nullif(kind, ''), 'd') = 'd'",
            "nullif(kind, NULL) = 'a'",
            "nullif(NULL::text, 'a') IS NULL",
            "coalesce(nullif(app.team(), 'a'), 'fallback') = 'fallback'"
          ],
          team <- ["x", "a", "", nil],
          kind <- ["a", "", nil] do
        expression_case(sql, team: team, kind: kind)
      end

    # COALESCE only evaluates what it needs. When the user id isn't a uuid, the cast is only reached if the
    # kind is NULL. The evaluator falls back on the cast either way
    lazy =
      for sql <- [
            "coalesce(kind, (app.user_id())::text) = 'a'",
            "coalesce(kind = 'a', (app.user_id())::text = 'x')",
            "nullif(kind, (app.user_id())::text) IS NULL"
          ],
          kind <- ["a", "b", nil] do
        expression_case(sql, user_id: "user_2abc", kind: kind)
      end

    # Postgres 17 raises 22012 division_by_zero here: the planner folds the constant argument before
    # COALESCE would stop at the first one, so the evaluator has to fall back
    folded_constant = [expression_case("coalesce(app.team(), (1 / 0)::text) = 'x'", team: "x")]

    # Constructs the evaluator doesn't model. They have to fall back, and Postgres has the answer
    unsupported =
      for sql <- [
            "length(app.team()) > 3",
            "lower(kind) = 'note'",
            "app.team() LIKE 'user:%'",
            "app.team() ILIKE 'USER:%'",
            "app.team() ~~ 'user:%'",
            "starts_with(app.team(), 'user:')",
            "split_part(app.team(), ':', 1) = 'user'",
            "app.team() = ANY (string_to_array('a,b', ','))",
            "CASE WHEN kind = 'note' THEN true ELSE false END",
            "CASE kind WHEN 'note' THEN true WHEN 'task' THEN NULL ELSE false END",
            "EXISTS (SELECT 1 FROM app.docs d2 WHERE d2.team = app.team())",
            "(select count(*) from app.docs) = 0",
            "kind IS DISTINCT FROM 'note'",
            "kind IS NOT DISTINCT FROM NULL",
            "(kind = 'note') IS TRUE",
            "(kind = 'note') IS NOT TRUE",
            "(kind = 'note') IS FALSE",
            "(kind = 'note') IS UNKNOWN",
            "kind BETWEEN 'a' AND 'c'",
            "kind > 'a'",
            "app.email() = 'a@b.c'",
            "current_setting('app.email', true) = 'a'",
            "current_setting('app.settings.foo', true) IS NULL",
            "current_setting('app.claims') IS NOT NULL",
            "current_setting('app.claim', true) IS NULL",
            "now() > '2000-01-01'::timestamptz"
          ],
          team <- ["user:abc", ""] do
        expression_case(sql, team: team)
      end

    concat ++ equality ++ unicode ++ any ++ null_tests ++ coalesce_and_nullif ++ lazy ++ folded_constant ++ unsupported
  end

  defp cases(:user_id_and_role) do
    templates = [
      "(app.user_id())::text = '#{@own}'",
      "app.user_id() = '#{@own}'::uuid",
      "app.user_id() IS NULL",
      "app.team() = 'user:' || app.user_id()",
      "(select app.user_id()) <> '#{@other}'::uuid",
      "coalesce(app.user_id() = '#{@own}'::uuid, false)"
    ]

    user_id =
      for flavor <- [:simple, :fallback], {_label, user_id} <- @user_ids, sql <- templates do
        expression_case(sql, [user_id: user_id, team: "user:#{@own}"], functions: flavor)
      end

    # Where the fallback body reads the claims: the user id is NULL, '' or set, and the claims disagree
    claims_fallback =
      for flavor <- [:simple, :fallback],
          sql <- ["app.user_id() = '#{@own}'::uuid", "app.user_id() IS NULL"],
          opts <- [
            [user_id: nil, claims: ~s({"sub":"#{@own}"})],
            [user_id: "", claims: ~s({"sub":"#{@own}"})],
            [user_id: "", claims: ~s({"sub":""})],
            [user_id: nil, claims: ~s({"sub":null})],
            [user_id: nil, claims: ~s({"sub":5})],
            [user_id: nil, claims: ~s({"sub":"user_2abc"})],
            [user_id: nil, claims: ~s({"sub":"#{@own}","sub":"#{@other}"})],
            [user_id: nil, claims: ~s({"x":{"sub":"#{@own}"}})],
            [user_id: nil, claims: "{}"],
            [user_id: nil, claims: "[]"],
            [user_id: nil, claims: ""],
            [user_id: nil, claims: nil],
            [user_id: nil, claims: "not json"],
            [user_id: nil, claims: ~s({"sub":"#{@own}","x":"\\u0000"})],
            [user_id: @own, claims: ~s({"sub":"#{@other}"})],
            [user_id: @own, claims: "not json"],
            [user_id: @own, claims: ~s({"x":"\\u0000"})],
            [user_id: @own, claims: nil]
          ] do
        expression_case(sql, opts, functions: flavor)
      end

    role =
      for flavor <- [:simple, :fallback],
          role <- ["member", "guest", "admin"],
          sql <- [
            "app.user_role() = 'member'",
            "(select app.user_role()) = 'guest'",
            "app.user_role() IS NULL",
            "app.user_role() <> 'admin'"
          ] do
        expression_case(sql, [role: role], functions: flavor)
      end

    role_claims_fallback =
      for flavor <- [:simple, :fallback],
          sql <- ["app.user_role() = 'member'", "app.user_role() IS NULL"],
          opts <- [
            [user_role: nil],
            [user_role: ""],
            [user_role: "guest"],
            [user_role: nil, claims: ~s({"role":"guest"})],
            [user_role: "", claims: ~s({"role":null})],
            [user_role: nil, claims: ~s({"role":"member","role":"guest"})],
            [user_role: nil, claims: "not json"],
            [user_role: "guest", claims: "not json"]
          ] do
        expression_case(sql, opts, functions: flavor)
      end

    user_id ++ claims_fallback ++ role ++ role_claims_fallback
  end

  defp cases(:claims) do
    # Values of a claim as JSON.encode!/1 encodes them
    values = [
      "v",
      "V",
      "",
      " v",
      "v ",
      "héllo",
      "日本語",
      "😀",
      "quote \"",
      "backslash \\",
      "newline \n",
      "tab \t",
      "slash /",
      "control \u0001",
      "del \u007f",
      "a" <> <<0>> <> "b",
      <<0>>,
      true,
      false,
      nil,
      0,
      1,
      -1,
      1.5,
      100.0,
      1.0e-7,
      12_345_678_901_234_567_890,
      %{"a" => 1},
      %{},
      [1, 2],
      [],
      "true",
      "1e2"
    ]

    from_jason =
      for value <- values,
          sql <- [
            "app.claims() ->> 'x' = #{claim_literal(value)}",
            "app.claims() ->> 'x' = 'v'",
            "app.claims() ->> 'x' IS NULL",
            "current_setting('app.claims', true)::jsonb ->> 'x' = #{claim_literal(value)}",
            "(select app.claims() ->> 'x') = 'v'",
            "(app.claims() ->> 'x')::boolean",
            "coalesce((app.claims() ->> 'x')::boolean, false)"
          ] do
        expression_case(sql, extra_claims: %{"x" => value})
      end

    # Claims written by hand, as JSON text
    raw = [
      {"duplicate keys, last wins", ~s({"x":"first","x":"last"})},
      {"duplicate keys, last is null", ~s({"x":"first","x":null})},
      {"duplicate keys, last is an object", ~s({"x":"first","x":{"a":1}})},
      {"duplicate keys of different case", ~s({"X":"1","x":"2"})},
      {"only nested", ~s({"y":{"x":"deep"}})},
      {"escaped unicode", ~s({"x":"caf\\u00e9"})},
      {"surrogate pair", ~s({"x":"\\ud83d\\ude00"})},
      {"lone high surrogate", ~s({"x":"\\ud83d"})},
      {"lone low surrogate", ~s({"x":"\\ude00"})},
      {"NUL escape", ~s({"x":"\\u0000"})},
      {"NUL escape in another value", ~s({"y":"\\u0000","x":"v"})},
      {"NUL escape in a key", ~s({"\\u0000":1,"x":"v"})},
      {"NUL escape in a key that is overwritten", ~s({"\\u0000":1,"x":"v","\\u0000":2})},
      {"slash escape", ~s({"x":"a\\/b"})},
      {"all simple escapes", ~s({"x":"\\b\\f\\n\\r\\t\\"\\\\"})},
      {"whitespace around everything", ~s( \n{ "x" : "v" }\t )},
      {"number 1e2", ~s({"x":1e2})},
      {"number 1E+2", ~s({"x":1E+2})},
      {"number 0.10", ~s({"x":0.10})},
      {"number -0", ~s({"x":-0})},
      {"number 1.50", ~s({"x":1.50})},
      {"number 1e-7", ~s({"x":1e-7})},
      {"a huge number", ~s({"x":100000000000000000000})},
      {"a nested object", ~s({"x":{"b":[1,{"c":null}],"a":"é"}})},
      {"true", ~s({"x":true})},
      {"top-level array", ~s(["x"])},
      {"top-level array of objects", ~s([{"x":"v"}])},
      {"top-level string", ~s("x")},
      {"top-level number", "5"},
      {"top-level null", "null"},
      {"top-level true", "true"},
      {"empty object", "{}"},
      {"empty text", ""},
      {"NULL", nil},
      {"a space", " "},
      {"a newline", "\n"},
      {"trailing comma", ~s({"x":"v",})},
      {"single quotes", "{'x':'v'}"},
      {"trailing garbage", ~s({"x":"v"} x)},
      {"unterminated", ~s({"x":"v")},
      {"truncated escape", ~s({"x":"\\u12"})},
      {"a raw tab in a string", ~s({"x":"a\tb"})},
      {"a raw newline in a string", ~s({"x":"a\nb"})},
      {"a BOM", "﻿" <> ~s({"x":"v"})},
      {"a key with unicode", ~s({"é":"v","x":"y"})},
      {"deeply nested", String.duplicate("[", 50) <> String.duplicate("]", 50)},
      {"not json", "not json"}
    ]

    from_raw =
      for {_label, json} <- raw,
          sql <- [
            "app.claims() ->> 'x' = 'v'",
            "app.claims() ->> 'x' IS NULL",
            "current_setting('app.claims', true)::jsonb ->> 'x' IS NULL",
            "app.claims() ->> 'é' = 'v'",
            "app.claims() ->> '' IS NULL"
          ] do
        expression_case(sql, claims: json)
      end

    # The usual ways to look at the token
    usual =
      for role <- ["member", "guest", "admin"],
          sql <- [
            "app.claims() ->> 'role' = 'member'",
            "(select app.claims() ->> 'role') = 'member'",
            "app.claims() ->> 'sub' = '#{@own}'",
            "(app.claims() ->> 'sub')::uuid = '#{@own}'::uuid",
            "(app.claims() -> 'meta') ->> 'role' = 'owner'",
            "(app.claims() -> 'meta' ->> 'role') = 'owner'",
            "app.claims() ->> 'email' = 'a@b.c'",
            "coalesce(app.claims() ->> 'email', '') = ''",
            "app.claims() ->> 'plan' = 'pro'",
            "(app.claims() ->> 'exp')::bigint > 0",
            "(app.claims() ->> 'x')::int > 0",
            "(app.claims() ->> 'x')::numeric > 0",
            "app.claims() ? 'x'",
            "app.claims() @> '{\"x\":\"v\"}'::jsonb",
            "app.claims() -> 'x' = '\"v\"'::jsonb"
          ],
          claims <- [
            %{"role" => role, "sub" => @own},
            %{
              "role" => role,
              "sub" => @own,
              "email" => "a@b.c",
              "plan" => "pro",
              "exp" => 1_900_000_000,
              "x" => "5",
              "meta" => %{"role" => "owner"}
            },
            %{"role" => role, "sub" => @own, "x" => "abc", "meta" => %{}}
          ] do
        expression_case(sql, role: role, claims: claims)
      end

    # What ::boolean accepts, from boolean.sql
    booleans =
      for text <-
            ~w(true TRUE True tRuE t T yes YES y Y on ON 1 false FALSE f F no n N off OFF of 0 maybe tru truee yess o on_ off_ 11 000 ye ya nope 2 -1) ++
              [
                "",
                "  ",
                " t ",
                " on ",
                "\ttrue",
                "true\n",
                "\n true \r",
                "\v t",
                "\ft\f",
                " true",
                "true ",
                "ｔｒｕｅ",
                "٣",
                "tr",
                "1 ",
                " 0",
                "t rue"
              ],
          sql <- [
            "(current_setting('app.claims', true)::jsonb ->> 'k')::boolean",
            "coalesce((app.claims() ->> 'k')::boolean, false)",
            "NOT (app.claims() ->> 'k')::boolean"
          ] do
        expression_case(sql, extra_claims: %{"k" => text})
      end

    headers =
      for headers <- [
            ~s({"user-agent":"v"}),
            ~s({"user-agent":"v","user-agent":"w"}),
            ~s({"User-Agent":"v"}),
            "{}",
            "[]",
            "",
            nil,
            "not json",
            ~s({"user-agent":null}),
            ~s({"user-agent":"\\u0000"}),
            ~s({"user-agent":1})
          ],
          sql <- [
            "current_setting('app.headers', true)::jsonb ->> 'user-agent' = 'v'",
            "current_setting('app.headers', true)::jsonb ->> 'user-agent' IS NULL",
            "current_setting('app.headers', true) IS NULL",
            "nullif(current_setting('app.headers', true), '') IS NULL",
            "current_setting('app.headers', true)::json ->> 'user-agent' = 'v'"
          ] do
        expression_case(sql, headers: headers)
      end

    settings =
      for sql <- [
            "current_setting('role', true) = 'member'",
            "current_setting('role', true) = 'guest'",
            "current_setting('app.user_role', true) = 'member'",
            "current_setting('app.user_role', true) IS NULL",
            "current_setting('app.user_id', true) = '#{@own}'",
            "current_setting('app.user_id', true) = ''",
            "current_setting('app.user_id', true) IS NULL",
            "nullif(current_setting('app.user_id', true), '') IS NULL",
            "current_setting('app.team', true) = 'room:1'",
            "current_setting('app.team', true) = ''",
            "current_setting('App.Claims', true) IS NULL",
            "current_setting('APP.USER_ID', true) = '#{@own}'",
            "current_setting('app.claims', true) = ''",
            "current_setting('app.claims', true) IS NOT NULL"
          ],
          opts <- [
            [],
            [user_id: nil],
            [user_id: ""],
            [role: "guest"],
            [team: nil],
            [team: ""],
            [claims: nil],
            [claims: ""],
            [user_role: nil]
          ] do
        expression_case(sql, opts)
      end

    from_jason ++ from_raw ++ usual ++ booleans ++ headers ++ settings
  end

  defp cases(:regex) do
    teams = [
      "public:lobby",
      "PUBLIC:LOBBY",
      "Public:Lobby",
      "xpublic:lobbyy",
      "room:1",
      "",
      nil,
      "a.b",
      "aXb",
      "x*y",
      "a\\b",
      "it's",
      "tab\there",
      "line\nbreak"
    ]

    patterns = [
      "public:lobby",
      "PUBLIC:LOBBY",
      "lobby",
      "LOBBY",
      "",
      "x",
      "a.b",
      "a|b",
      "x*",
      "^public",
      "lobby$",
      "[a-z]",
      "\\d",
      "(?i)PUBLIC",
      "***:public",
      "***=public",
      "a{2}",
      "a}b",
      "a]b",
      ":",
      "_",
      "%",
      "-",
      " ",
      "'",
      "\\",
      "e",
      "É",
      "é",
      "İ",
      "ſ",
      "K"
    ]

    ascii =
      for team <- teams, pattern <- patterns, operator <- ["~", "~*"] do
        expression_case("app.team() #{operator} #{lit(pattern)}", team: team)
      end

    unicode_teams = [
      "café",
      "CAFÉ",
      "Café",
      "İstanbul",
      "istanbul",
      "ISTANBUL",
      "Kelvin K",
      "kelvin k",
      "straße",
      "STRASSE",
      "ſs",
      "Σίσυφος",
      "ΣΊΣΥΦΟΣ"
    ]

    unicode_patterns = ["é", "É", "caf", "CAF", "i", "I", "k", "K", "s", "S", "ss", "σ", "Σ", ""]

    unicode =
      for team <- unicode_teams, pattern <- unicode_patterns, operator <- ["~", "~*"] do
        expression_case("app.team() #{operator} #{lit(pattern)}", team: team)
      end

    others =
      for sql <- [
            "app.team() ~ NULL::text",
            "app.team() ~* NULL::text",
            "NULL::text ~ 'a'",
            "'abc' ~ 'b'",
            "'ABC' ~* 'b'",
            "'ABC' ~ 'b'",
            "kind ~ 'ot'",
            "kind ~* 'OT'",
            "NOT (app.team() ~ 'a')",
            "NOT (app.team() ~* 'A')",
            "app.team() ~ 'a' AND kind ~* 'B'",
            "app.team() !~ 'a'",
            "app.team() !~* 'a'",
            "app.team() ~ kind",
            "app.team() ~ ('a' || kind)",
            "app.team() ~ app.user_role()"
          ],
          team <- ["a", "A", "", nil],
          kind <- ["note", nil] do
        expression_case(sql, team: team, kind: kind)
      end

    ascii ++ unicode ++ others
  end

  defp cases(:literals) do
    # uuid_in's accepted forms, from uuid.sql. A literal is deparsed to its canonical form.
    uuid_forms = [
      "11111111-1111-1111-1111-111111111111",
      "{11111111-1111-1111-1111-111111111111}",
      "11111111111111111111111111111111",
      "1111-1111-1111-1111-1111-1111-1111-1111",
      "{1111-1111-1111-1111-1111-1111-1111-1111}",
      "A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11",
      "a0eebc99-9c0b4ef8-bb6d6bb9-bd380a11",
      "{a0eebc99-9c0b4ef8-bb6d6bb9-bd380a11}",
      "a0eebc999c0b4ef8bb6d6bb9bd380a11",
      "a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11"
    ]

    uuid_literals =
      for form <- uuid_forms,
          user_id <- ["a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "11111111-1111-1111-1111-111111111111", nil],
          sql <- [
            "app.user_id() = #{lit(form)}::uuid",
            "#{lit(form)}::uuid <> app.user_id()",
            "(#{lit(form)}::uuid)::text = 'x'"
          ] do
        expression_case(sql, user_id: user_id)
      end

    boolean_literals =
      for form <- ~w(t true yes on 1 f false no off 0 y n),
          sql <- [
            "#{lit(form)}::boolean",
            "#{lit(form)}::boolean AND kind = 'note'",
            "NOT #{lit(form)}::boolean"
          ] do
        expression_case(sql)
      end

    jsonb_literals =
      for json <- [
            ~s({"x": "v"}),
            ~s({"x":"v"}),
            ~s({"x":"first","x":"v"}),
            ~s({"x":1e2}),
            ~s({"x": 1.50}),
            ~s({"x": true}),
            ~s({"x": null}),
            ~s({"x": {"a": [1, 2, {"b": null}]}}),
            ~s({"x": "caf\\u00e9"}),
            ~s({"x": "\\ud83d\\ude00"}),
            ~s({"x": "a\\nb"}),
            ~s({"x": "a\\"b"}),
            ~s({"x": "a\\\\b"}),
            ~s({"x": "it's"}),
            "{}",
            "[]",
            ~s(["x"]),
            ~s("x"),
            "5",
            "null"
          ],
          sql <- [
            "#{lit(json)}::jsonb ->> 'x' = 'v'",
            "#{lit(json)}::jsonb ->> 'x' IS NULL",
            "#{lit(json)}::jsonb ->> 'x' = '100'",
            "#{lit(json)}::jsonb ->> 'x' = 'café'"
          ] do
        expression_case(sql)
      end

    # An operand that raises (the cast of a user id that isn't a uuid) next to one that would decide. Postgres
    # evaluates the left side first and raises where it is reached, so the evaluator has to fall back
    # (a decided answer there is a mismatch), and also where it isn't reached, it can't know that
    raising_operand =
      [
        expression_case("(app.user_id())::text = 'x' OR kind = 'note'", user_id: "user_2abc"),
        expression_case("(app.user_id())::text = 'x' AND kind = 'nope'", user_id: "user_2abc"),
        expression_case("NOT ((app.user_id())::text = 'x' AND kind = 'nope')", user_id: "user_2abc"),
        # and where it is not reached
        expression_case("kind = 'note' OR (app.user_id())::text = 'x'", user_id: "user_2abc"),
        expression_case("kind = 'nope' AND (app.user_id())::text = 'x'", user_id: "user_2abc"),
        expression_case("true OR (app.user_id())::text = 'x'", user_id: "user_2abc"),
        expression_case("false AND (app.user_id())::text = 'x'", user_id: "user_2abc"),
        expression_case("(app.user_id())::text = 'x' OR true", user_id: "user_2abc"),
        expression_case("(app.user_id())::text = 'x' AND false", user_id: "user_2abc"),
        # both sides raise, or neither decides
        expression_case("(app.user_id())::text = 'x' OR (app.user_id())::text = 'y'", user_id: "user_2abc"),
        expression_case("(app.user_id())::text = 'x' AND kind = 'note'", user_id: "user_2abc"),
        expression_case("(app.user_id())::text = 'x' OR kind = 'nope'", user_id: "user_2abc")
      ]

    # Strings, from strings.sql
    strings =
      for sql <- [
            "'abc' || 'def' = 'abcdef'",
            "'abc' || NULL IS NULL",
            "'' || '' = ''",
            "'a' = 'a '",
            "'a' = 'A'",
            "'' = ''",
            "NULL::text = NULL::text",
            "NULL::text IS NULL",
            "'a' <> 'b'",
            "'a' <> NULL",
            "NOT ('a' = 'b')",
            "'é' = 'é'",
            "'é' || 'e' = 'ée'"
          ] do
        expression_case(sql)
      end

    uuid_literals ++ boolean_literals ++ jsonb_literals ++ raising_operand ++ strings
  end

  defp claim_text(value) when is_binary(value), do: value
  defp claim_text(nil), do: "null"
  defp claim_text(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp claim_text(value), do: JSON.encode!(value)

  # A SQL literal can't hold NUL, so it's dropped
  defp claim_literal(value), do: value |> claim_text() |> String.replace(<<0>>, "") |> lit()
end
