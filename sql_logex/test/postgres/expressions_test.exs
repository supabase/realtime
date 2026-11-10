defmodule SqlLogex.Postgres.ExpressionsTest do
  # Level 1 of the differential tests: the evaluator gives the value that Postgres gives, for
  # single expressions, or falls back when it cannot be sure. Postgres is the oracle. Every case
  # runs through both, and SqlLogex.Differential compares the answers.
  #
  #   mix test test/postgres/expressions_test.exs
  #   SQL_LOGEX_REPORT=1 mix test test/postgres/expressions_test.exs   # coverage report
  #
  # A policy is created with the expression as a policy author writes it, and `pg_get_expr` is read
  # back: that is the text that the library gets. Postgres runs the deparsed text in a SELECT,
  # against a row of a table, with the settings of the case. The evaluator parses and evaluates the
  # same text. Each case runs in a transaction that rolls back.
  use ExUnit.Case, async: false

  alias SqlLogex.Differential
  alias SqlLogex.Eval
  alias SqlLogex.Parser
  alias SqlLogex.Resolver
  alias SqlLogex.Test.Collector
  alias SqlLogex.Test.Postgres
  alias SqlLogex.Test.RealtimeDatabase
  alias SqlLogex.Test.RealtimeProfile
  alias SqlLogex.Test.RealtimeScenarios

  @moduletag :postgres
  @moduletag timeout: 600_000

  @profile RealtimeProfile.profile()

  @own "c0ffee00-1111-4222-8333-444455556666"
  @other "deadbeef-0000-4000-8000-000000000001"

  # Strings that stand for a sub, the ways Postgres's uuid_in reads them, and the ways it doesn't
  @subs [
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

  @groups [:three_valued, :text_and_arrays, :uid_and_role, :claims, :regex, :literals]

  setup_all do
    %{collector: Collector.start(:expressions)}
  end

  setup do
    %{conn: start_supervised!(Postgres)}
  end

  for group <- @groups do
    test "expressions: #{group}", %{conn: conn, collector: collector} do
      functions = %{
        legacy: load_functions(conn, :legacy),
        supabase_auth: load_functions(conn, :supabase_auth)
      }

      results = Enum.map(cases(unquote(group)), &run_case(conn, functions, unquote(group), &1))

      Collector.finish(collector, results)
    end
  end

  ## The runner

  # The definitions of the functions of the profile in the database, with the bodies of a flavor.
  # The legacy bodies are the ones of the supabase/postgres image, supabase/auth's are what
  # production projects run.
  defp load_functions(conn, flavor) do
    Postgres.rolled_back(conn, fn conn ->
      prepare_functions!(conn, flavor)
      Postgres.read_functions(conn, @profile)
    end)
  end

  defp prepare_functions!(_conn, :legacy), do: :ok

  defp prepare_functions!(conn, :supabase_auth),
    do: Postgrex.query!(conn, RealtimeDatabase.supabase_auth_functions_statement(), [])

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
    #{RealtimeScenarios.describe_env(kase.env, kase.env.extension)}
    """

    Differential.compare(pg, ex, name: kase.name, group: group, detail: detail)
  end

  defp create_policy_and_read_back!(conn, kase) do
    create_policy = "CREATE POLICY tmp ON realtime.messages FOR SELECT TO authenticated USING (#{kase.sql})"

    case Postgrex.query(conn, create_policy, []) do
      {:ok, _result} -> :ok
      {:error, error} -> raise "#{inspect(kase.name)}: #{Exception.message(error)}\nwhile running:\n#{create_policy}"
    end

    %{rows: [[deparsed]]} =
      Postgrex.query!(
        conn,
        "SELECT pg_get_expr(polqual, polrelid) FROM pg_policy WHERE polrelid = 'realtime.messages'::regclass AND polname = 'tmp'",
        []
      )

    deparsed
  end

  # What Postgres evaluates the deparsed text to, with the settings and the row of the case
  defp postgres_value(conn, deparsed, env) do
    # The row is in a table. As a VALUES list with parameters it would be a constant for the planner,
    # which folds what a constant allows: NULLIF(NULL, <raises>) is NULL there, and raises on a column.
    # A policy is evaluated against a column of the table
    Postgrex.query!(conn, "CREATE TEMP TABLE m AS SELECT $1::text AS topic, $2::text AS extension", [
      env.row_topic,
      env.extension
    ])

    Postgrex.query!(conn, "GRANT SELECT ON m TO PUBLIC", [])
    RealtimeScenarios.set_settings!(conn, env)

    case Postgrex.query(conn, "SELECT #{deparsed} FROM pg_temp.m", []) do
      {:ok, %Postgrex.Result{rows: [[value]]}} -> {:ok, value}
      {:error, %Postgrex.Error{} = error} -> Postgres.error(error)
    end
  end

  defp evaluate(deparsed, env, functions) do
    {ir, _type} = deparsed |> Parser.parse() |> Resolver.resolve(functions, @profile)

    case Eval.eval(ir, RealtimeScenarios.logex_env(env, env.extension)) do
      {:unsupported, reason} -> {:unsupported, reason}
      value -> {:value, value}
    end
  rescue
    exception -> {:crash, Exception.format(:error, exception, __STACKTRACE__)}
  end

  ## The cases

  # An expression as a policy author writes it, the environment it is run in, and the bodies of the
  # auth functions in the database
  defp expression_case(sql, env_opts \\ [], opts \\ []) do
    functions = Keyword.get(opts, :functions, :legacy)
    env_summary = if env_opts == [], do: "", else: " with #{inspect(env_opts, limit: 8, printable_limit: 60)}"
    functions_summary = if functions == :legacy, do: "", else: " (#{functions} functions)"

    %{
      name: sql <> env_summary <> functions_summary,
      sql: sql,
      env: RealtimeScenarios.env(env_opts),
      functions: functions
    }
  end

  defp lit(string), do: "'" <> String.replace(string, "'", "''") <> "'"

  defp cases(:three_valued) do
    constants =
      for(a <- ~w(true false NULL), b <- ~w(true false NULL), op <- ~w(AND OR), do: expression_case("#{a} #{op} #{b}")) ++
        for(a <- ~w(true false NULL), do: expression_case("NOT #{a}"))

    # A is true, false or NULL by the topic, B by the extension
    expressions = [
      "realtime.topic() = 'a' AND extension = 'x'",
      "realtime.topic() = 'a' OR extension = 'x'",
      "NOT (realtime.topic() = 'a')",
      "NOT (realtime.topic() = 'a' AND extension = 'x')",
      "NOT (realtime.topic() = 'a' OR extension = 'x')",
      "NOT (realtime.topic() = 'a') OR extension = 'x'",
      "NOT (realtime.topic() = 'a') AND NOT (extension = 'x')",
      "realtime.topic() = 'a' AND (extension = 'x' OR NOT (realtime.topic() = 'a'))",
      "(realtime.topic() = 'a' OR extension = 'x') AND realtime.topic() <> 'b'",
      "realtime.topic() = 'a' AND extension = 'x' AND realtime.topic() <> 'b'",
      "realtime.topic() = 'a' OR extension = 'x' OR realtime.topic() = 'b'",
      "(realtime.topic() = 'a') IS NULL",
      "(realtime.topic() = 'a' AND extension = 'x') IS NOT NULL",
      "NOT (extension IS NULL) AND realtime.topic() IS NOT NULL",
      # Where one side is something we don't evaluate, and the other may decide
      "realtime.topic() = 'a' OR lower(extension) = 'x'",
      "realtime.topic() = 'a' AND lower(extension) = 'x'",
      "lower(extension) = 'x' OR realtime.topic() = 'a'",
      "lower(extension) = 'x' AND realtime.topic() = 'a'",
      "NOT (lower(extension) = 'x')",
      "NOT (lower(extension) = 'x' AND realtime.topic() = 'a')"
    ]

    sources =
      for expression <- expressions, topic <- ["a", "b", nil], extension <- ["x", "y", nil] do
        expression_case(expression, topic: topic, extension: extension)
      end

    constants ++ sources
  end

  defp cases(:text_and_arrays) do
    concat =
      for sql <- [
            "realtime.topic() = 'x' || NULL",
            "realtime.topic() = 'a' || NULL",
            "('x' || realtime.topic()) = 'xa'",
            "('x' || realtime.topic()) IS NULL",
            "realtime.topic() || extension = 'ab'",
            "(realtime.topic() || extension) IS NULL",
            "coalesce(realtime.topic() || extension, 'none') = 'none'",
            "'a' || 'b' = 'ab'",
            "realtime.topic() = 'a' || 'b'",
            "extension || '' = ''",
            "'' || extension = extension",
            "'x' || NULL IS NULL",
            "NOT ('x' || NULL IS NULL)",
            "realtime.topic() <> 'x' || extension"
          ],
          topic <- ["a", "ab", "", nil],
          extension <- ["b", nil] do
        expression_case(sql, topic: topic, extension: extension)
      end

    equality =
      for sql <- [
            "realtime.topic() = 'x'",
            "realtime.topic() <> 'x'",
            "extension = 'x'",
            "realtime.topic() = extension",
            "'x' = realtime.topic()",
            "realtime.topic() IN ('x')",
            "realtime.topic() NOT IN ('x')",
            "realtime.topic() = ''",
            "realtime.topic() <> ''"
          ],
          topic <- [
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
        expression_case(sql, topic: topic, extension: "x")
      end

    # Also against the NFC and NFD spelling of é
    unicode =
      for topic <- ["é", "é"], literal <- ["é", "é"] do
        expression_case("realtime.topic() = #{lit(literal)}", topic: topic)
      end

    any =
      for sql <- [
            "extension IN ('a', 'b')",
            "extension IN ('a', NULL)",
            "extension IN ('a', 'b', NULL)",
            "extension NOT IN ('a', 'b')",
            "extension NOT IN ('a', NULL)",
            "extension IN ('a')",
            "extension NOT IN ('a')",
            "NOT (extension IN ('a', 'b'))",
            "NOT (extension NOT IN ('a', 'b'))",
            "extension = ANY ('{}'::text[])",
            "extension = ANY (ARRAY[]::text[])",
            "extension <> ALL ('{}'::text[])",
            "extension <> ALL (ARRAY[]::text[])",
            "extension = ANY (ARRAY['a', 'b'])",
            "extension = ANY (ARRAY['a', NULL])",
            "extension <> ALL (ARRAY['a', NULL])",
            "extension = ANY ('{a,b}'::text[])",
            "extension = ANY ('{a,NULL}'::text[])",
            "extension = ANY (ARRAY[realtime.topic(), 'z'])",
            "realtime.topic() IN (extension, 'z')",
            "realtime.topic() NOT IN (extension, 'z')",
            "extension IN ('a', 'b') AND extension NOT IN ('b')",
            "(extension IN ('a', NULL)) IS NULL",
            "NOT (extension = ANY ('{}'::text[]))"
          ],
          extension <- ["a", "b", "c", nil],
          topic <- ["a", "z", nil] do
        expression_case(sql, topic: topic, extension: extension)
      end

    null_tests =
      for sql <- [
            "extension IS NULL",
            "extension IS NOT NULL",
            "realtime.topic() IS NULL",
            "realtime.topic() IS NOT NULL",
            "NOT (realtime.topic() IS NULL)",
            "(extension = 'a') IS NULL",
            "(extension = 'a') IS NOT NULL",
            "realtime.topic() IS NULL OR extension IS NULL",
            "realtime.topic() IS NOT NULL AND extension IS NOT NULL"
          ],
          topic <- ["a", "", nil],
          extension <- ["a", nil] do
        expression_case(sql, topic: topic, extension: extension)
      end

    coalesce_and_nullif =
      for sql <- [
            "coalesce(realtime.topic(), 'x') = 'x'",
            "coalesce(realtime.topic(), extension, 'z') = 'z'",
            "coalesce(NULL::text, extension) = 'a'",
            "coalesce(extension = 'a', false)",
            "coalesce(extension = 'a', true)",
            "coalesce(extension = 'a', realtime.topic() = 'a')",
            "coalesce(NULL::boolean, NULL::boolean) IS NULL",
            "nullif(realtime.topic(), 'x') = 'y'",
            "nullif(realtime.topic(), 'x') IS NULL",
            "nullif(extension, realtime.topic()) IS NULL",
            "nullif(extension, realtime.topic()) = extension",
            "coalesce(nullif(extension, ''), 'd') = 'd'",
            "nullif(extension, NULL) = 'a'",
            "nullif(NULL::text, 'a') IS NULL",
            "coalesce(nullif(realtime.topic(), 'a'), 'fallback') = 'fallback'"
          ],
          topic <- ["x", "a", "", nil],
          extension <- ["a", "", nil] do
        expression_case(sql, topic: topic, extension: extension)
      end

    # COALESCE only evaluates what it needs. When the sub isn't a uuid, the cast is only reached if the
    # extension is NULL. The evaluator falls back on the cast either way
    lazy =
      for sql <- [
            "coalesce(extension, (auth.uid())::text) = 'a'",
            "coalesce(extension = 'a', (auth.uid())::text = 'x')",
            "nullif(extension, (auth.uid())::text) IS NULL"
          ],
          extension <- ["a", "b", nil] do
        expression_case(sql, sub: "user_2abc", extension: extension)
      end

    # Postgres 17 raises 22012 division_by_zero here: the planner folds the constant argument before
    # COALESCE would stop at the first one, so the evaluator has to fall back
    folded_constant = [expression_case("coalesce(realtime.topic(), (1 / 0)::text) = 'x'", topic: "x")]

    # Constructs the evaluator doesn't model. They have to fall back, and Postgres has the answer
    unsupported =
      for sql <- [
            "length(realtime.topic()) > 3",
            "lower(extension) = 'broadcast'",
            "realtime.topic() LIKE 'user:%'",
            "realtime.topic() ILIKE 'USER:%'",
            "realtime.topic() ~~ 'user:%'",
            "starts_with(realtime.topic(), 'user:')",
            "split_part(realtime.topic(), ':', 1) = 'user'",
            "realtime.topic() = ANY (string_to_array('a,b', ','))",
            "CASE WHEN extension = 'broadcast' THEN true ELSE false END",
            "CASE extension WHEN 'broadcast' THEN true WHEN 'presence' THEN NULL ELSE false END",
            "EXISTS (SELECT 1 FROM realtime.messages m2 WHERE m2.topic = realtime.topic())",
            "(select count(*) from realtime.messages) = 0",
            "extension IS DISTINCT FROM 'broadcast'",
            "extension IS NOT DISTINCT FROM NULL",
            "(extension = 'broadcast') IS TRUE",
            "(extension = 'broadcast') IS NOT TRUE",
            "(extension = 'broadcast') IS FALSE",
            "(extension = 'broadcast') IS UNKNOWN",
            "extension BETWEEN 'a' AND 'c'",
            "extension > 'a'",
            "auth.email() = 'a@b.c'",
            "current_setting('request.jwt.claim.email', true) = 'a'",
            "current_setting('app.settings.foo', true) IS NULL",
            "current_setting('request.jwt.claims') IS NOT NULL",
            "current_setting('request.jwt.claim', true) IS NULL",
            "now() > '2000-01-01'::timestamptz"
          ],
          topic <- ["user:abc", ""] do
        expression_case(sql, topic: topic)
      end

    concat ++ equality ++ unicode ++ any ++ null_tests ++ coalesce_and_nullif ++ lazy ++ folded_constant ++ unsupported
  end

  defp cases(:uid_and_role) do
    templates = [
      "(auth.uid())::text = '#{@own}'",
      "auth.uid() = '#{@own}'::uuid",
      "auth.uid() IS NULL",
      "realtime.topic() = 'user:' || auth.uid()",
      "(select auth.uid()) <> '#{@other}'::uuid",
      "coalesce(auth.uid() = '#{@own}'::uuid, false)"
    ]

    uid =
      for flavor <- [:legacy, :supabase_auth], {_label, sub} <- @subs, sql <- templates do
        expression_case(sql, [sub: sub, topic: "user:#{@own}"], functions: flavor)
      end

    # Where supabase/auth's body falls back to the claims: sub is NULL, '' or set, and the claims disagree
    claims_fallback =
      for flavor <- [:legacy, :supabase_auth],
          sql <- ["auth.uid() = '#{@own}'::uuid", "auth.uid() IS NULL"],
          opts <- [
            [sub: nil, claims: ~s({"sub":"#{@own}"})],
            [sub: "", claims: ~s({"sub":"#{@own}"})],
            [sub: "", claims: ~s({"sub":""})],
            [sub: nil, claims: ~s({"sub":null})],
            [sub: nil, claims: ~s({"sub":5})],
            [sub: nil, claims: ~s({"sub":"user_2abc"})],
            [sub: nil, claims: ~s({"sub":"#{@own}","sub":"#{@other}"})],
            [sub: nil, claims: ~s({"x":{"sub":"#{@own}"}})],
            [sub: nil, claims: "{}"],
            [sub: nil, claims: "[]"],
            [sub: nil, claims: ""],
            [sub: nil, claims: nil],
            [sub: nil, claims: "not json"],
            [sub: nil, claims: ~s({"sub":"#{@own}","x":"\\u0000"})],
            [sub: @own, claims: ~s({"sub":"#{@other}"})],
            [sub: @own, claims: "not json"],
            [sub: @own, claims: ~s({"x":"\\u0000"})],
            [sub: @own, claims: nil]
          ] do
        expression_case(sql, opts, functions: flavor)
      end

    role =
      for flavor <- [:legacy, :supabase_auth],
          role <- ["authenticated", "anon", "service_role"],
          sql <- [
            "auth.role() = 'authenticated'",
            "(select auth.role()) = 'anon'",
            "auth.role() IS NULL",
            "auth.role() <> 'service_role'"
          ] do
        expression_case(sql, [role: role], functions: flavor)
      end

    role_claims_fallback =
      for flavor <- [:legacy, :supabase_auth],
          sql <- ["auth.role() = 'authenticated'", "auth.role() IS NULL"],
          opts <- [
            [claim_role: nil],
            [claim_role: ""],
            [claim_role: "anon"],
            [claim_role: nil, claims: ~s({"role":"anon"})],
            [claim_role: "", claims: ~s({"role":null})],
            [claim_role: nil, claims: ~s({"role":"authenticated","role":"anon"})],
            [claim_role: nil, claims: "not json"],
            [claim_role: "anon", claims: "not json"]
          ] do
        expression_case(sql, opts, functions: flavor)
      end

    uid ++ claims_fallback ++ role ++ role_claims_fallback
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
            "auth.jwt() ->> 'x' = #{claim_literal(value)}",
            "auth.jwt() ->> 'x' = 'v'",
            "auth.jwt() ->> 'x' IS NULL",
            "current_setting('request.jwt.claims', true)::jsonb ->> 'x' = #{claim_literal(value)}",
            "(select auth.jwt() ->> 'x') = 'v'",
            "(auth.jwt() ->> 'x')::boolean",
            "coalesce((auth.jwt() ->> 'x')::boolean, false)"
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
            "auth.jwt() ->> 'x' = 'v'",
            "auth.jwt() ->> 'x' IS NULL",
            "current_setting('request.jwt.claims', true)::jsonb ->> 'x' IS NULL",
            "auth.jwt() ->> 'é' = 'v'",
            "auth.jwt() ->> '' IS NULL"
          ] do
        expression_case(sql, claims: json)
      end

    # The usual ways to look at the token
    usual =
      for role <- ["authenticated", "anon", "service_role"],
          sql <- [
            "auth.jwt() ->> 'role' = 'authenticated'",
            "(select auth.jwt() ->> 'role') = 'authenticated'",
            "auth.jwt() ->> 'sub' = '#{@own}'",
            "(auth.jwt() ->> 'sub')::uuid = '#{@own}'::uuid",
            "(auth.jwt() -> 'app_metadata') ->> 'role' = 'admin'",
            "(auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'",
            "auth.jwt() ->> 'email' = 'a@b.c'",
            "coalesce(auth.jwt() ->> 'email', '') = ''",
            "auth.jwt() ->> 'aal' = 'aal2'",
            "(auth.jwt() ->> 'exp')::bigint > 0",
            "(auth.jwt() ->> 'x')::int > 0",
            "(auth.jwt() ->> 'x')::numeric > 0",
            "auth.jwt() ? 'x'",
            "auth.jwt() @> '{\"x\":\"v\"}'::jsonb",
            "auth.jwt() -> 'x' = '\"v\"'::jsonb"
          ],
          claims <- [
            %{"role" => role, "sub" => @own},
            %{
              "role" => role,
              "sub" => @own,
              "email" => "a@b.c",
              "aal" => "aal2",
              "exp" => 1_900_000_000,
              "x" => "5",
              "app_metadata" => %{"role" => "admin"}
            },
            %{"role" => role, "sub" => @own, "x" => "abc", "app_metadata" => %{}}
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
            "(current_setting('request.jwt.claims', true)::jsonb ->> 'k')::boolean",
            "coalesce((auth.jwt() ->> 'k')::boolean, false)",
            "NOT (auth.jwt() ->> 'k')::boolean"
          ] do
        expression_case(sql, extra_claims: %{"k" => text})
      end

    headers =
      for headers <- [
            ~s({"x-client-info":"v"}),
            ~s({"x-client-info":"v","x-client-info":"w"}),
            ~s({"X-Client-Info":"v"}),
            "{}",
            "[]",
            "",
            nil,
            "not json",
            ~s({"x-client-info":null}),
            ~s({"x-client-info":"\\u0000"}),
            ~s({"x-client-info":1})
          ],
          sql <- [
            "current_setting('request.headers', true)::jsonb ->> 'x-client-info' = 'v'",
            "current_setting('request.headers', true)::jsonb ->> 'x-client-info' IS NULL",
            "current_setting('request.headers', true) IS NULL",
            "nullif(current_setting('request.headers', true), '') IS NULL",
            "current_setting('request.headers', true)::json ->> 'x-client-info' = 'v'"
          ] do
        expression_case(sql, headers: headers)
      end

    settings =
      for sql <- [
            "current_setting('role', true) = 'authenticated'",
            "current_setting('role', true) = 'anon'",
            "current_setting('request.jwt.claim.role', true) = 'authenticated'",
            "current_setting('request.jwt.claim.role', true) IS NULL",
            "current_setting('request.jwt.claim.sub', true) = '#{@own}'",
            "current_setting('request.jwt.claim.sub', true) = ''",
            "current_setting('request.jwt.claim.sub', true) IS NULL",
            "nullif(current_setting('request.jwt.claim.sub', true), '') IS NULL",
            "current_setting('realtime.topic', true) = 'room:1'",
            "current_setting('realtime.topic', true) = ''",
            "current_setting('Request.JWT.Claims', true) IS NULL",
            "current_setting('REQUEST.JWT.CLAIM.SUB', true) = '#{@own}'",
            "current_setting('request.jwt.claims', true) = ''",
            "current_setting('request.jwt.claims', true) IS NOT NULL"
          ],
          opts <- [
            [],
            [sub: nil],
            [sub: ""],
            [role: "anon"],
            [topic: nil],
            [topic: ""],
            [claims: nil],
            [claims: ""],
            [claim_role: nil]
          ] do
        expression_case(sql, opts)
      end

    from_jason ++ from_raw ++ usual ++ booleans ++ headers ++ settings
  end

  defp cases(:regex) do
    topics = [
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
      for topic <- topics, pattern <- patterns, operator <- ["~", "~*"] do
        expression_case("realtime.topic() #{operator} #{lit(pattern)}", topic: topic)
      end

    unicode_topics = [
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
      for topic <- unicode_topics, pattern <- unicode_patterns, operator <- ["~", "~*"] do
        expression_case("realtime.topic() #{operator} #{lit(pattern)}", topic: topic)
      end

    others =
      for sql <- [
            "realtime.topic() ~ NULL::text",
            "realtime.topic() ~* NULL::text",
            "NULL::text ~ 'a'",
            "'abc' ~ 'b'",
            "'ABC' ~* 'b'",
            "'ABC' ~ 'b'",
            "extension ~ 'cast'",
            "extension ~* 'CAST'",
            "NOT (realtime.topic() ~ 'a')",
            "NOT (realtime.topic() ~* 'A')",
            "realtime.topic() ~ 'a' AND extension ~* 'B'",
            "realtime.topic() !~ 'a'",
            "realtime.topic() !~* 'a'",
            "realtime.topic() ~ extension",
            "realtime.topic() ~ ('a' || extension)",
            "realtime.topic() ~ auth.role()"
          ],
          topic <- ["a", "A", "", nil],
          extension <- ["broadcast", nil] do
        expression_case(sql, topic: topic, extension: extension)
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
          sub <- ["a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "11111111-1111-1111-1111-111111111111", nil],
          sql <- [
            "auth.uid() = #{lit(form)}::uuid",
            "#{lit(form)}::uuid <> auth.uid()",
            "(#{lit(form)}::uuid)::text = 'x'"
          ] do
        expression_case(sql, sub: sub)
      end

    boolean_literals =
      for form <- ~w(t true yes on 1 f false no off 0 y n),
          sql <- [
            "#{lit(form)}::boolean",
            "#{lit(form)}::boolean AND extension = 'broadcast'",
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

    # An operand that raises (the cast of a sub that isn't a uuid) next to one that would decide. Postgres
    # evaluates the left side first and raises where it is reached, so the evaluator has to fall back
    # (a decided answer there is a mismatch), and also where it isn't reached, it can't know that
    raising_operand =
      [
        expression_case("(auth.uid())::text = 'x' OR extension = 'broadcast'", sub: "user_2abc"),
        expression_case("(auth.uid())::text = 'x' AND extension = 'nope'", sub: "user_2abc"),
        expression_case("NOT ((auth.uid())::text = 'x' AND extension = 'nope')", sub: "user_2abc"),
        # and where it is not reached
        expression_case("extension = 'broadcast' OR (auth.uid())::text = 'x'", sub: "user_2abc"),
        expression_case("extension = 'nope' AND (auth.uid())::text = 'x'", sub: "user_2abc"),
        expression_case("true OR (auth.uid())::text = 'x'", sub: "user_2abc"),
        expression_case("false AND (auth.uid())::text = 'x'", sub: "user_2abc"),
        expression_case("(auth.uid())::text = 'x' OR true", sub: "user_2abc"),
        expression_case("(auth.uid())::text = 'x' AND false", sub: "user_2abc"),
        # both sides raise, or neither decides
        expression_case("(auth.uid())::text = 'x' OR (auth.uid())::text = 'y'", sub: "user_2abc"),
        expression_case("(auth.uid())::text = 'x' AND extension = 'broadcast'", sub: "user_2abc"),
        expression_case("(auth.uid())::text = 'x' OR extension = 'nope'", sub: "user_2abc")
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
