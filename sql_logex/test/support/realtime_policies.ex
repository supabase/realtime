defmodule SqlLogex.Test.RealtimePolicies do
  @moduledoc """
  Policies on `realtime.messages`, as `CREATE POLICY` statements, for the tests against Postgres
  and for the fixtures in `test/fixtures`. Create them in a transaction that rolls back.

  The `generator_*` policies are a set of typical policies of the example. A few of them fail or are
  slow on purpose.
  """

  # Fixed, so that the text Postgres prints for them is the same on every run
  @generator_params %{topic: "fixture_topic", role: "authenticated", sub: "c0ffee00-1111-4222-8333-444455556666"}

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
  The statements of the generator policies, named `generator_<name>`, for the params that the
  fixtures use. The `broken_*` ones call `public.test_log_error()`, which
  `SqlLogex.Test.RealtimeDatabase` creates.
  """
  @spec generator_statements() :: [String.t()]
  def generator_statements, do: generator_statements(@generator_names, @generator_params)

  @doc "The statements of the generator policies `names`, with `params`, named as in `generator_statements/0`."
  @spec generator_statements([atom()], map()) :: [String.t()]
  def generator_statements(names, params), do: Enum.map(names, &generator(&1, params))

  # Each policy is named generator_<name>, so that all of them can exist at the same time.
  defp generator(:authenticated_all_topic_read, _params) do
    """
    CREATE POLICY "generator_authenticated_all_topic_read"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( true );
    """
  end

  defp generator(:authenticated_all_topic_insert, _params) do
    """
    CREATE POLICY "generator_authenticated_all_topic_insert"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( true );
    """
  end

  defp generator(:authenticated_read_matching_user_sub, %{sub: sub}) do
    """
    CREATE POLICY "generator_authenticated_read_matching_user_sub"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING (((SELECT auth.uid() AS uid)::text) = '#{sub}')
    """
  end

  defp generator(:read_matching_user_role, %{role: role}) do
    """
    CREATE POLICY "generator_read_matching_user_role"
    ON realtime.messages FOR SELECT
    USING (((SELECT auth.role())::text) = '#{role}')
    """
  end

  defp generator(:authenticated_write_matching_user_sub, %{sub: sub}) do
    """
    CREATE POLICY "generator_authenticated_write_matching_user_sub"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK (((SELECT auth.uid() AS uid)::text) = '#{sub}')
    """
  end

  defp generator(:write_matching_user_role, %{role: role}) do
    """
    CREATE POLICY "generator_write_matching_user_role"
    ON realtime.messages FOR INSERT
    WITH CHECK (((SELECT auth.role())::text) = '#{role}')
    """
  end

  defp generator(:authenticated_read_broadcast, %{topic: name}) do
    """
    CREATE POLICY "generator_authenticated_read_broadcast"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'broadcast' );
    """
  end

  defp generator(:authenticated_write_broadcast, %{topic: name}) do
    """
    CREATE POLICY "generator_authenticated_write_broadcast"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'broadcast');
    """
  end

  defp generator(:authenticated_write_persistence, %{topic: name}) do
    """
    CREATE POLICY "generator_authenticated_write_persistence"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'persistence');
    """
  end

  defp generator(:authenticated_read_presence, %{topic: name}) do
    """
    CREATE POLICY "generator_authenticated_read_presence"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'presence' );
    """
  end

  defp generator(:authenticated_write_presence, %{topic: name}) do
    """
    CREATE POLICY "generator_authenticated_write_presence"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' AND realtime.messages.extension = 'presence' );
    """
  end

  defp generator(:authenticated_read_presence_for_sub, %{topic: name, sub: sub}) do
    """
    CREATE POLICY "generator_authenticated_read_presence_for_sub"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING (
      realtime.topic() = '#{name}'
      AND realtime.messages.extension = 'presence'
      AND ((SELECT auth.uid())::text) = '#{sub}'
    );
    """
  end

  defp generator(:authenticated_read_broadcast_and_presence, %{topic: name}) do
    """
    CREATE POLICY "generator_authenticated_read_broadcast_and_presence"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING ( realtime.topic() = '#{name}' AND realtime.messages.extension IN ('presence', 'broadcast') );
    """
  end

  defp generator(:authenticated_write_broadcast_and_presence, %{topic: name}) do
    """
    CREATE POLICY "generator_authenticated_write_broadcast_and_presence"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( realtime.topic() = '#{name}' AND realtime.messages.extension IN ('presence', 'broadcast') );
    """
  end

  defp generator(:authenticated_read_presence_based_on_claim, %{topic: name}) do
    """
    CREATE POLICY "generator_authenticated_read_presence_based_on_claim"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING (
      realtime.topic() = '#{name}'
      AND realtime.messages.extension = 'presence'
      AND coalesce(((current_setting('request.jwt.claims', true))::jsonb ->> 'presence_read')::boolean, false)
    );
    """
  end

  defp generator(:authenticated_read_broadcast_based_on_claim, %{topic: name}) do
    """
    CREATE POLICY "generator_authenticated_read_broadcast_based_on_claim"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING (
      realtime.topic() = '#{name}'
      AND realtime.messages.extension = 'broadcast'
      AND coalesce(((current_setting('request.jwt.claims', true))::jsonb ->> 'broadcast_read')::boolean, false)
    );
    """
  end

  defp generator(:broken_read_presence, _params) do
    """
    CREATE POLICY "generator_broken_read_presence"
    ON realtime.messages FOR SELECT
    TO authenticated
    USING (  (SELECT test_log_error())  );
    """
  end

  defp generator(:broken_write_presence, _params) do
    """
    CREATE POLICY "generator_broken_write_presence"
    ON realtime.messages FOR INSERT
    TO authenticated
    WITH CHECK ( (SELECT test_log_error()) );
    """
  end

  defp generator(:slow_read, _params) do
    """
    CREATE POLICY "generator_slow_read"
    ON realtime.messages AS RESTRICTIVE FOR SELECT
    TO authenticated
    USING ( (SELECT true FROM pg_sleep(1)) );
    """
  end

  defp generator(:slow_write, _params) do
    """
    CREATE POLICY "generator_slow_write"
    ON realtime.messages AS RESTRICTIVE FOR INSERT
    TO authenticated
    WITH CHECK ( (SELECT true FROM pg_sleep(1)) );
    """
  end

  defp policy(name, definition), do: ~s(CREATE POLICY "#{name}" ON realtime.messages #{definition})

  defp select(name, using), do: policy("grammar_#{name}", "FOR SELECT TO authenticated USING (#{using})")
end
