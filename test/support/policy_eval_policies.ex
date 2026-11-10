defmodule PolicyEvalPolicies do
  @moduledoc """
  Policies on `realtime.messages` shared by the policy_eval tests, as `CREATE POLICY` statements.

  Create them in a transaction that is rolled back, they are not meant to persist.

  policy_eval has a copy as its worked example, `PolicyEval.Test.RealtimePolicies` in
  policy_eval/test/support. The two copies do not have to stay equal.
  """

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

  Whitespace aside, these are the bodies `Realtime.Tenants.PolicyEvalProfile` knows. Run it in a transaction that is
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

  @doc """
  The `Generators.policy_query/2` statements for `names`, with `params`.

  Their names are replaced by `generator_<name>`: two pairs of generators use the same policy name
  (`authenticated_read_presence` and `authenticated_read_broadcast_and_presence`, and their write
  counterparts), so they cannot all exist at the same time otherwise.
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
end
