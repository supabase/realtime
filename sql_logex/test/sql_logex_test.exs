defmodule SqlLogexTest do
  # SQL in, value out: what a policy expression evaluates to, through parser, resolver and evaluator.
  #
  # The expressions are written the way Postgres prints them (pg_get_expr), the only form the parser
  # reads. Every expected value here was checked against Postgres 17. A fallback, `{:unsupported, _}`,
  # is where the database is asked instead; the comment says what Postgres answers there. The
  # differential test in Realtime (test/realtime/tenants/sql_logex_differential_test.exs) does the
  # same against Postgres for thousands of expressions, written as customers write them.
  use ExUnit.Case, async: true

  alias SqlLogex.Env
  alias SqlLogex.Eval
  alias SqlLogex.Parser
  alias SqlLogex.Resolver

  @uid "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @other_uid "b1ffcd00-8d1c-4ff9-cc7e-7cc0ce491b22"

  # auth.uid(), auth.role(), auth.jwt() and realtime.topic() as Postgres 17 reports them: the bodies
  # of the supabase/postgres image, and supabase/auth's auth.jwt()
  {catalog, _binding} = Code.eval_file(Path.expand("fixtures/pg17/catalog.exs", __DIR__))
  @functions catalog.functions

  # supabase/auth's auth.uid() (migration 20220224000811), which also reads the sub from the claims
  @uid_supabase_auth """
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
  """

  @own_channel_rls "(realtime.topic() = ('user:'::text || auth.uid()))"

  # Evaluates `sql` in the session Realtime sets up for a join: the settings for a JWT with this
  # role, sub and claims, and the probe row with this topic and extension. A nil sub is a JWT
  # without one.
  defp evaluate(sql, opts) do
    {ir, _type} = sql |> Parser.parse() |> Resolver.resolve(Keyword.get(opts, :functions, @functions))
    Eval.eval(ir, env(opts))
  end

  # The functions above, with these changes to the definition of auth.uid()
  defp with_auth_uid(changes) do
    Enum.map(@functions, fn
      %{schema: "auth", name: "uid"} = function -> Map.merge(function, changes)
      function -> function
    end)
  end

  defp env(opts) do
    role = Keyword.get(opts, :role, "authenticated")
    sub = Keyword.get(opts, :sub)
    topic = Keyword.get(opts, :topic, "room:1")
    claims = Keyword.get_lazy(opts, :claims, fn -> JSON.encode!(%{"role" => role, "sub" => sub}) end)

    Env.new(
      %{
        "role" => role,
        "realtime.topic" => topic,
        "request.jwt.claims" => claims,
        "request.jwt.claim.sub" => sub,
        "request.jwt.claim.role" => role,
        "request.headers" => "{}"
      },
      %{"topic" => {:text, topic}, "extension" => {:text, Keyword.get(opts, :extension, "broadcast")}}
    )
  end

  describe "a user's own channel" do
    test "is the topic user:<their uid>" do
      assert evaluate(@own_channel_rls, topic: "user:#{@uid}", sub: @uid) == true
      assert evaluate(@own_channel_rls, topic: "user:#{@other_uid}", sub: @uid) == false
    end

    test "is the same in the (select auth.uid()) form" do
      initplan = "(realtime.topic() = ('user:'::text || ( SELECT auth.uid() AS uid)))"

      assert evaluate(initplan, topic: "user:#{@uid}", sub: @uid) == true
      assert evaluate(initplan, topic: "user:#{@other_uid}", sub: @uid) == false
    end

    test "compares the uid as Postgres prints it, in lower case" do
      assert evaluate(@own_channel_rls, topic: "user:#{@uid}", sub: String.upcase(@uid)) == true
      assert evaluate(@own_channel_rls, topic: "user:#{String.upcase(@uid)}", sub: @uid) == false
    end

    test "is NULL without a sub, which denies" do
      assert evaluate(@own_channel_rls, topic: "user:", sub: nil) == nil
    end

    test "falls back for a sub that isn't a uuid, where Postgres raises" do
      assert evaluate(@own_channel_rls, topic: "user:user_2abc", sub: "user_2abc") ==
               {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type uuid"}}
    end

    test "depends on the body of auth.uid(): supabase/auth's also reads the sub from the claims" do
      opts = [topic: "user:#{@uid}", sub: "", claims: ~s({"sub":"#{@uid}"})]

      assert evaluate(@own_channel_rls, [functions: with_auth_uid(%{source: @uid_supabase_auth})] ++ opts) == true
      assert evaluate(@own_channel_rls, opts) == nil
    end
  end

  describe "lists" do
    test "IN is = ANY over an array" do
      sql = "(extension = ANY (ARRAY['broadcast'::text, 'presence'::text]))"

      assert evaluate(sql, extension: "presence") == true
      assert evaluate(sql, extension: "postgres_changes") == false
    end
  end

  describe "regular expressions" do
    test "a literal pattern is an unanchored match, ~* ignores ASCII case" do
      sql = "(realtime.topic() ~* 'public:lobby'::text)"

      assert evaluate(sql, topic: "PUBLIC:LOBBY") == true
      assert evaluate(sql, topic: "xpublic:lobbyy") == true
      assert evaluate(sql, topic: "room:1") == false
    end

    test "fall back for a pattern with metacharacters, or ~* on a topic that isn't ASCII" do
      # Postgres: true, then false
      assert evaluate("(realtime.topic() ~ '^public'::text)", topic: "public:lobby") ==
               {:unsupported, :regex_not_literal}

      assert evaluate("(realtime.topic() ~* 'public:lobby'::text)", topic: "café") ==
               {:unsupported, :regex_non_ascii}
    end
  end

  describe "claims" do
    test "are read from the JWT with auth.jwt() ->>" do
      sql = "((auth.jwt() ->> 'role'::text) = 'authenticated'::text)"

      assert evaluate(sql, claims: ~s({"role":"authenticated"})) == true
      assert evaluate(sql, claims: ~s({"role":"anon"})) == false
      assert evaluate(sql, claims: ~s({})) == nil
    end

    test "cast to boolean as Postgres reads booleans" do
      sql = "((auth.jwt() ->> 'is_admin'::text))::boolean"

      assert evaluate(sql, claims: ~s({"is_admin":true})) == true
      assert evaluate(sql, claims: ~s({"is_admin":"yes"})) == true

      assert evaluate(sql, claims: ~s({"is_admin":"maybe"})) ==
               {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type boolean"}}
    end

    test "fall back for a number, whose text Postgres normalises" do
      # Postgres: true
      assert evaluate("((auth.jwt() ->> 'level'::text) = '1'::text)", claims: ~s({"level":1})) ==
               {:unsupported, :jsonb_number_text}
    end
  end

  describe "NULL" do
    test "follows SQL's three-valued logic" do
      null = "(realtime.topic() = NULL::text)"

      assert evaluate(null, []) == nil
      assert evaluate("(NOT #{null})", []) == nil
      assert evaluate("(#{null} OR (extension = 'broadcast'::text))", []) == true
      assert evaluate("(#{null} AND (extension = 'broadcast'::text))", []) == nil
      assert evaluate("(#{null} AND (extension = 'presence'::text))", []) == false
    end
  end

  describe "falling back rather than guessing" do
    test "an unsupported part decides an OR even next to a true one" do
      # Postgres: true. It may evaluate the unsupported part first or while planning, and raise
      sql = "((extension = 'broadcast'::text) OR (realtime.topic() ~ 'a.b'::text))"

      assert evaluate(sql, extension: "broadcast") == {:unsupported, :regex_not_literal}
    end

    test "a COALESCE with an unsupported argument, even after a non-NULL one" do
      # Postgres raises division_by_zero: the planner folds the constant 1 / 0 before COALESCE
      # would stop at realtime.topic(). Here 1 / 0 is unsupported because numbers aren't modelled
      # at all (hence the reason); what the test shows is that COALESCE doesn't skip it.
      assert {:unsupported, {:number_literal, "1"}} =
               evaluate("(COALESCE(realtime.topic(), ((1 / 0))::text) = 'x'::text)", topic: "x")
    end

    test "a column other than topic and extension" do
      assert evaluate("(event = 'x'::text)", []) == {:unsupported, {:column, "event"}}
    end

    test "a function whose definition isn't one of the known ones" do
      for changes <- [%{source: "select '#{@uid}'::uuid;"}, %{security_definer: true}] do
        assert evaluate(@own_channel_rls, topic: "user:#{@uid}", sub: @uid, functions: with_auth_uid(changes)) ==
                 {:unsupported, {:function, "auth.uid", :unknown_definition}}
      end
    end

    test "an expression over 4 KB" do
      # Postgres: true
      sql = "(" <> Enum.map_join(1..200, " OR ", &"(realtime.topic() = 'room:#{&1}'::text)") <> ")"

      assert byte_size(sql) > 4096
      assert evaluate(sql, topic: "room:1") == {:unsupported, {:unparsed, sql}}
    end
  end
end
