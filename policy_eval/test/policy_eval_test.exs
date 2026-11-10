defmodule PolicyEvalTest do
  # SQL in, value out: what a policy expression evaluates to, through parser, resolver and evaluator.
  #
  # The expressions are written the way Postgres prints them (pg_get_expr), the only form the parser
  # reads. Every expected value here was checked against Postgres 17. A fallback, `{:unsupported, _}`,
  # is where the database is asked instead; the comment says what Postgres answers there.
  # test/postgres/expressions_test.exs does the same against Postgres for thousands of expressions,
  # written as policy authors write them.
  use ExUnit.Case, async: true

  alias PolicyEval.Env
  alias PolicyEval.Eval
  alias PolicyEval.Parser
  alias PolicyEval.Resolver
  alias PolicyEval.Test.ExampleProfile

  @profile ExampleProfile.profile()

  @uid "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @other_uid "b1ffcd00-8d1c-4ff9-cc7e-7cc0ce491b22"

  # app.team(), app.user_id(), app.user_role() and app.claims() as Postgres 17 reports them, with the
  # simple bodies of app.user_id() and app.user_role()
  {catalog, _binding} = Code.eval_file(Path.expand("fixtures/pg17/catalog.exs", __DIR__))
  @functions catalog.functions

  # The fallback body of app.user_id(), which also reads the sub from the claims
  @user_id_fallback """
  select
    coalesce(
      nullif(current_setting('app.user_id', true), ''),
      (nullif(current_setting('app.claims', true), '')::jsonb ->> 'sub')
    )::uuid
  """

  @own_team_rls "(app.team() = ('user:'::text || app.user_id()))"

  # Evaluates `sql` in the session that the application of the example sets up: the settings for a
  # user with this role, user id and claims, and the row with this team and kind. A nil user id is
  # a user without one.
  defp evaluate(sql, opts) do
    {ir, _type} = sql |> Parser.parse() |> Resolver.resolve(Keyword.get(opts, :functions, @functions), @profile)
    Eval.eval(ir, env(opts))
  end

  # The functions above, with these changes to the definition of app.user_id()
  defp with_user_id(changes) do
    Enum.map(@functions, fn
      %{schema: "app", name: "user_id"} = function -> Map.merge(function, changes)
      function -> function
    end)
  end

  defp env(opts) do
    role = Keyword.get(opts, :role, "member")
    user_id = Keyword.get(opts, :user_id)
    team = Keyword.get(opts, :team, "room:1")
    claims = Keyword.get_lazy(opts, :claims, fn -> JSON.encode!(%{"role" => role, "sub" => user_id}) end)

    Env.new(
      %{
        "role" => role,
        "app.team" => team,
        "app.claims" => claims,
        "app.user_id" => user_id,
        "app.user_role" => role
      },
      %{"team" => {:text, team}, "kind" => {:text, Keyword.get(opts, :kind, "note")}}
    )
  end

  describe "a user's own team" do
    test "is the team user:<their user id>" do
      assert evaluate(@own_team_rls, team: "user:#{@uid}", user_id: @uid) == true
      assert evaluate(@own_team_rls, team: "user:#{@other_uid}", user_id: @uid) == false
    end

    test "is the same in the (select app.user_id()) form" do
      initplan = "(app.team() = ('user:'::text || ( SELECT app.user_id() AS user_id)))"

      assert evaluate(initplan, team: "user:#{@uid}", user_id: @uid) == true
      assert evaluate(initplan, team: "user:#{@other_uid}", user_id: @uid) == false
    end

    test "compares the user id as Postgres prints it, in lower case" do
      assert evaluate(@own_team_rls, team: "user:#{@uid}", user_id: String.upcase(@uid)) == true
      assert evaluate(@own_team_rls, team: "user:#{String.upcase(@uid)}", user_id: @uid) == false
    end

    test "is NULL without a user id, which denies" do
      assert evaluate(@own_team_rls, team: "user:", user_id: nil) == nil
    end

    test "falls back for a user id that isn't a uuid, where Postgres raises" do
      assert evaluate(@own_team_rls, team: "user:user_2abc", user_id: "user_2abc") ==
               {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type uuid"}}
    end

    test "depends on the body of app.user_id(): the fallback body also reads the sub from the claims" do
      opts = [team: "user:#{@uid}", user_id: "", claims: ~s({"sub":"#{@uid}"})]

      assert evaluate(@own_team_rls, [functions: with_user_id(%{source: @user_id_fallback})] ++ opts) == true
      assert evaluate(@own_team_rls, opts) == nil
    end
  end

  describe "lists" do
    test "IN is = ANY over an array" do
      sql = "(kind = ANY (ARRAY['note'::text, 'task'::text]))"

      assert evaluate(sql, kind: "task") == true
      assert evaluate(sql, kind: "comment") == false
    end
  end

  describe "regular expressions" do
    test "a literal pattern is an unanchored match, ~* ignores ASCII case" do
      sql = "(app.team() ~* 'public:lobby'::text)"

      assert evaluate(sql, team: "PUBLIC:LOBBY") == true
      assert evaluate(sql, team: "xpublic:lobbyy") == true
      assert evaluate(sql, team: "room:1") == false
    end

    test "fall back for a pattern with metacharacters, or ~* on a team that isn't ASCII" do
      # Postgres: true, then false
      assert evaluate("(app.team() ~ '^public'::text)", team: "public:lobby") ==
               {:unsupported, :regex_not_literal}

      assert evaluate("(app.team() ~* 'public:lobby'::text)", team: "café") ==
               {:unsupported, :regex_non_ascii}
    end
  end

  describe "LIKE" do
    test "% matches any run and _ one character, on the whole text" do
      sql = "(app.team() ~~ 'public:%'::text)"

      assert evaluate(sql, team: "public:lobby") == true
      assert evaluate(sql, team: "xpublic:lobby") == false
      assert evaluate(sql, team: "publicx:lobby") == false
      assert evaluate(sql, team: "public::lobby") == true
      assert evaluate(sql, team: "room:1") == false
      assert evaluate("(app.team() ~~ 'room:_'::text)", team: "room:1") == true
    end

    test "NOT LIKE is the negation, and NULL stays NULL" do
      sql = "(app.team() !~~ 'public:%'::text)"

      assert evaluate(sql, team: "public:lobby") == false
      assert evaluate(sql, team: "room:1") == true
      assert evaluate(sql, team: nil) == nil
    end

    test "fall back for a pattern with a backslash, or ILIKE" do
      # Postgres: true, then true
      assert evaluate("(app.team() ~~ 'public\\:%'::text)", team: "public:lobby") ==
               {:unsupported, :like_escape}

      assert evaluate("(app.team() ~~* 'PUBLIC:%'::text)", team: "public:lobby") ==
               {:unsupported, {:operator, "~~*", :text, :text}}
    end
  end

  describe "claims" do
    test "are read with app.claims() ->>" do
      sql = "((app.claims() ->> 'role'::text) = 'member'::text)"

      assert evaluate(sql, claims: ~s({"role":"member"})) == true
      assert evaluate(sql, claims: ~s({"role":"guest"})) == false
      assert evaluate(sql, claims: ~s({})) == nil
    end

    test "cast to boolean as Postgres reads booleans" do
      sql = "((app.claims() ->> 'is_admin'::text))::boolean"

      assert evaluate(sql, claims: ~s({"is_admin":true})) == true
      assert evaluate(sql, claims: ~s({"is_admin":"yes"})) == true

      assert evaluate(sql, claims: ~s({"is_admin":"maybe"})) ==
               {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type boolean"}}
    end

    test "fall back for a number, whose text Postgres normalises" do
      # Postgres: true
      assert evaluate("((app.claims() ->> 'level'::text) = '1'::text)", claims: ~s({"level":1})) ==
               {:unsupported, :jsonb_number_text}
    end
  end

  describe "NULL" do
    test "follows SQL's three-valued logic" do
      null = "(app.team() = NULL::text)"

      assert evaluate(null, []) == nil
      assert evaluate("(NOT #{null})", []) == nil
      assert evaluate("(#{null} OR (kind = 'note'::text))", []) == true
      assert evaluate("(#{null} AND (kind = 'note'::text))", []) == nil
      assert evaluate("(#{null} AND (kind = 'task'::text))", []) == false
    end
  end

  describe "falling back rather than guessing" do
    test "an unsupported part decides an OR even next to a true one" do
      # Postgres: true. It may evaluate the unsupported part first or while planning, and raise
      sql = "((kind = 'note'::text) OR (app.team() ~ 'a.b'::text))"

      assert evaluate(sql, kind: "note") == {:unsupported, :regex_not_literal}
    end

    test "a COALESCE with an unsupported argument, even after a non-NULL one" do
      # Postgres raises division_by_zero: the planner folds the constant 1 / 0 before COALESCE
      # would stop at app.team(). Here 1 / 0 is unsupported because numbers aren't modelled
      # at all (hence the reason); what the test shows is that COALESCE doesn't skip it.
      assert {:unsupported, :number_literal} =
               evaluate("(COALESCE(app.team(), ((1 / 0))::text) = 'x'::text)", team: "x")
    end

    test "a column other than team and kind" do
      assert evaluate("(title = 'x'::text)", []) == {:unsupported, {:column, "title"}}
    end

    test "a function whose definition isn't one of the known ones" do
      for changes <- [%{source: "select '#{@uid}'::uuid;"}, %{security_definer: true}] do
        assert evaluate(@own_team_rls, team: "user:#{@uid}", user_id: @uid, functions: with_user_id(changes)) ==
                 {:unsupported, {:function, "app.user_id", :unknown_definition}}
      end
    end

    test "an expression over 4 KB" do
      # Postgres: true
      sql = "(" <> Enum.map_join(1..200, " OR ", &"(app.team() = 'room:#{&1}'::text)") <> ")"

      assert byte_size(sql) > 4096
      assert evaluate(sql, team: "room:1") == {:unsupported, {:unparsed, :other}}
    end
  end
end
