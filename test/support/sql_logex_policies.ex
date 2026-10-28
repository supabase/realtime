defmodule SqlLogexPolicies do
  @moduledoc """
  Policies on `realtime.messages` shared by the sql_logex tests, as `CREATE POLICY` statements.

  Create them in a transaction that is rolled back, they are not meant to persist.
  """

  # Fixed so that the text Postgres reports for them is the same on every run
  @generator_params %{topic: "fixture_topic", role: "authenticated", sub: "c0ffee00-1111-4222-8333-444455556666"}

  # Every clause of Generators.policy_query/2
  @generator_names ~w(
    authenticated_all_topic_read
    authenticated_all_topic_insert
    authenticated_read_matching_user_sub
    read_matching_user_role
    authenticated_write_matching_user_sub
    write_matching_user_role
    authenticated_read_broadcast
    authenticated_write_broadcast
    authenticated_write_persistence
    authenticated_read_presence
    authenticated_write_presence
    authenticated_read_presence_for_sub
    authenticated_read_broadcast_and_presence
    authenticated_write_broadcast_and_presence
    authenticated_read_presence_based_on_claim
    authenticated_read_broadcast_based_on_claim
    broken_read_presence
    broken_write_presence
    slow_read
    slow_write
  )a

  @doc """
  Creates `auth.jwt()` when the database has none.

  supabase/auth creates it, the supabase/postgres image of the test tenant databases only has `auth.uid()`,
  `auth.role()` and `auth.email()`, and policies calling it cannot be created without it. Same body as
  supabase/auth's migrations/20220531120530_add_auth_jwt_function.up.sql (github.com/supabase/auth),
  whitespace aside. A database that has the function keeps its own.
  """
  @spec auth_jwt_statement() :: String.t()
  def auth_jwt_statement do
    """
    DO $do$
    BEGIN
      IF to_regprocedure('auth.jwt()') IS NULL THEN
        CREATE FUNCTION auth.jwt() RETURNS jsonb LANGUAGE sql STABLE AS $body$
          select coalesce(
                   nullif(current_setting('request.jwt.claim', true), ''),
                   nullif(current_setting('request.jwt.claims', true), '')
                 )::jsonb
        $body$;
      END IF;
    END
    $do$
    """
  end

  @doc """
  Replaces `auth.uid()` and `auth.role()` with the bodies supabase/auth has installed since its migration
  20220224000811, which production projects run (github.com/supabase/auth). They fall back to the
  claims when the `request.jwt.claim.sub`/`.role` setting is empty, where the ones of the
  supabase/postgres image only read the setting.

  Whitespace aside, these are the bodies `SqlLogex.Catalog` knows. Run it in a transaction that is
  rolled back.
  """
  @spec supabase_auth_functions_statement() :: String.t()
  def supabase_auth_functions_statement do
    """
    DO $do$
    BEGIN
      CREATE OR REPLACE FUNCTION auth.uid() RETURNS uuid LANGUAGE sql STABLE AS $body$
        select
        coalesce(
          nullif(current_setting('request.jwt.claim.sub', true), ''),
          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
        )::uuid
      $body$;

      CREATE OR REPLACE FUNCTION auth.role() RETURNS text LANGUAGE sql STABLE AS $body$
        select
        coalesce(
          nullif(current_setting('request.jwt.claim.role', true), ''),
          (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
        )::text
      $body$;
    END
    $do$
    """
  end

  @doc "The user-channel policies, in the plain and in the initplan `(select auth.uid())` form."
  @spec user_channel_policies() :: [String.t()]
  def user_channel_policies do
    own_channel(:plain) ++ [lobby_policy()] ++ own_channel(:initplan)
  end

  @doc """
  A common user-channel policy set: the `lobby` policy and the two policies for the own channel,
  in the plain (`auth.uid()`) or the initplan (`(select auth.uid())`) form.
  """
  @spec user_channel_policies(:plain | :initplan) :: [String.t()]
  def user_channel_policies(form) when form in [:plain, :initplan], do: own_channel(form) ++ [lobby_policy()]

  defp own_channel(:plain) do
    [
      policy("users receive on own channel", """
      FOR SELECT TO authenticated
      USING (realtime.topic() = 'user:' || auth.uid() AND extension IN ('broadcast','presence'))
      """),
      policy("users send on own channel", """
      FOR INSERT TO authenticated
      WITH CHECK (realtime.topic() = 'user:' || auth.uid() AND extension IN ('broadcast','presence'))
      """)
    ]
  end

  defp own_channel(:initplan) do
    [
      policy("users receive on own channel (initplan)", """
      FOR SELECT TO authenticated
      USING (realtime.topic() = 'user:' || (select auth.uid()) AND extension IN ('broadcast','presence'))
      """),
      policy("users send on own channel (initplan)", """
      FOR INSERT TO authenticated
      WITH CHECK (realtime.topic() = 'user:' || (select auth.uid()) AND extension IN ('broadcast','presence'))
      """)
    ]
  end

  defp lobby_policy do
    policy("lobby", """
    FOR SELECT TO authenticated
    USING (realtime.topic() ~* 'public:lobby')
    """)
  end

  @doc "One construct per policy, to exercise the grammar the parser has to handle."
  @spec grammar_policies() :: [String.t()]
  def grammar_policies do
    [
      select("not", "NOT (realtime.topic() = 'x')"),
      select("is_null", "realtime.topic() IS NULL"),
      select("is_not_null", "realtime.topic() IS NOT NULL"),
      select("neq", "realtime.topic() <> 'x'"),
      select("in_single", "extension IN ('broadcast')"),
      select("not_in", "extension NOT IN ('broadcast', 'presence')"),
      select("not_in_single", "extension NOT IN ('broadcast')"),
      select("coalesce", "coalesce(realtime.topic(), 'x') = 'x'"),
      select("nullif", "nullif(realtime.topic(), 'x') = 'y'"),
      select("jwt_text", "auth.jwt() ->> 'k' = 'v'"),
      select("jwt_text_initplan", "(select auth.jwt() ->> 'k') = 'v'"),
      select("claims_text", "current_setting('request.jwt.claims', true)::jsonb ->> 'k' = 'v'"),
      select("claims_boolean", "(current_setting('request.jwt.claims', true)::jsonb ->> 'k')::boolean"),
      select("regex_case_sensitive", "realtime.topic() ~ 'public:lobby'"),
      select("true", "true"),
      select("false", "false"),
      select("eq_null", "realtime.topic() = NULL"),
      select("concat_null", "realtime.topic() = 'x' || NULL"),
      select("and_in_or", "realtime.topic() = 'a' OR (realtime.topic() = 'b' AND extension = 'broadcast')"),
      select("or_in_and", "(realtime.topic() = 'a' OR realtime.topic() = 'b') AND extension = 'broadcast'"),
      select("and_three", "realtime.topic() = 'a' AND extension = 'broadcast' AND private = true"),
      select("doubled_quote", "realtime.topic() = 'it''s'"),
      select("exists", "EXISTS (SELECT 1 FROM realtime.messages m2 WHERE m2.topic = realtime.topic())"),
      select("case_searched", "CASE WHEN extension = 'broadcast' THEN true ELSE false END"),
      select("case_simple", "CASE extension WHEN 'broadcast' THEN true ELSE false END"),
      select("auth_role", "auth.role() = 'authenticated'"),
      select("private", "private = true"),
      select("event", "event = 'x'"),
      policy("grammar_all_using_only", "FOR ALL TO authenticated USING (realtime.topic() = 'x')"),
      policy("grammar_restrictive", "AS RESTRICTIVE FOR SELECT TO authenticated USING (realtime.topic() = 'x')"),
      policy("grammar_to_public", "FOR SELECT USING (realtime.topic() = 'x')"),
      policy("grammar_to_anon_authenticated", "FOR SELECT TO anon, authenticated USING (realtime.topic() = 'x')")
    ]
  end

  @doc """
  The `Generators.policy_query/2` policies and the params they need.

  Create them with `generator_statements/0`. `test_log_error()` is also needed by the `broken_*` ones
  and is created by `Generators.create_rls_policies/3`, with an empty list of policies.
  """
  @spec generator_policies() :: %{names: [atom()], params: map()}
  def generator_policies, do: %{names: @generator_names, params: @generator_params}

  @doc """
  The `Generators.policy_query/2` statements for all `generator_policies/0`.

  Their names are replaced by `generator_<name>`: two pairs of generators use the same policy name
  (`authenticated_read_presence` and `authenticated_read_broadcast_and_presence`, and their write
  counterparts), so they cannot all exist at the same time otherwise.
  """
  @spec generator_statements() :: [String.t()]
  def generator_statements, do: generator_statements(@generator_names, @generator_params)

  @doc """
  The `Generators.policy_query/2` statements for `names`, with `params`, named as in `generator_statements/0`.
  """
  @spec generator_statements([atom()], map()) :: [String.t()]
  def generator_statements(names, params) do
    for name <- names do
      name
      |> Generators.policy_query(params)
      |> String.replace(~r/\ACREATE POLICY "[^"]*"/, ~s(CREATE POLICY "generator_#{name}"))
    end
  end

  defp policy(name, definition), do: ~s(CREATE POLICY "#{name}" ON realtime.messages #{definition})

  defp select(name, using), do: policy("grammar_#{name}", "FOR SELECT TO authenticated USING (#{using})")
end
