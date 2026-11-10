defmodule PolicyEval.Test.ExamplePolicies do
  @moduledoc """
  Policies on `app.docs`, as `CREATE POLICY` statements, for the tests against Postgres and for
  the fixtures in `test/fixtures`. Create them in a transaction that rolls back.

  The `typical_*` policies are a set of typical policies of the example. A few of them fail or are
  slow on purpose.
  """

  # Fixed, so that the text Postgres prints for them is the same on every run
  @typical_params %{team: "fixture_team", role: "member", user_id: "c0ffee00-1111-4222-8333-444455556666"}

  @typical_names ~w(
    member_read_all
    member_insert_all
    member_read_matching_user_id
    read_matching_user_role
    member_write_matching_user_id
    write_matching_user_role
    member_read_notes
    member_write_notes
    member_write_files
    member_read_tasks
    member_write_tasks
    member_read_own_tasks
    member_read_notes_and_tasks
    member_write_notes_and_tasks
    member_read_tasks_by_claim
    member_read_notes_by_claim
    broken_read
    broken_write
    slow_read
    slow_write
  )a

  @doc "The personal-team policies, in the plain and in the initplan `(select app.user_id())` form."
  @spec personal_team_policies() :: [String.t()]
  def personal_team_policies do
    own_team(:plain) ++ [lobby_policy()] ++ own_team(:initplan)
  end

  @doc """
  A common policy set for personal teams: a member reads and writes notes and tasks in the team
  `user:<their id>`, and reads the `lobby` team. The own-team policies are in the plain
  (`app.user_id()`) or the initplan (`(select app.user_id())`) form.
  """
  @spec personal_team_policies(:plain | :initplan) :: [String.t()]
  def personal_team_policies(form) when form in [:plain, :initplan], do: own_team(form) ++ [lobby_policy()]

  defp own_team(:plain) do
    [
      policy("members read in their own team", """
      FOR SELECT TO member
      USING (app.team() = 'user:' || app.user_id() AND kind IN ('note','task'))
      """),
      policy("members write in their own team", """
      FOR INSERT TO member
      WITH CHECK (app.team() = 'user:' || app.user_id() AND kind IN ('note','task'))
      """)
    ]
  end

  defp own_team(:initplan) do
    [
      policy("members read in their own team (initplan)", """
      FOR SELECT TO member
      USING (app.team() = 'user:' || (select app.user_id()) AND kind IN ('note','task'))
      """),
      policy("members write in their own team (initplan)", """
      FOR INSERT TO member
      WITH CHECK (app.team() = 'user:' || (select app.user_id()) AND kind IN ('note','task'))
      """)
    ]
  end

  defp lobby_policy do
    policy("lobby", """
    FOR SELECT TO member
    USING (app.team() ~* 'public:lobby')
    """)
  end

  @doc "One construct per policy, to exercise the grammar the parser has to handle."
  @spec grammar_policies() :: [String.t()]
  def grammar_policies do
    [
      select("not", "NOT (app.team() = 'x')"),
      select("is_null", "app.team() IS NULL"),
      select("is_not_null", "app.team() IS NOT NULL"),
      select("neq", "app.team() <> 'x'"),
      select("in_single", "kind IN ('note')"),
      select("not_in", "kind NOT IN ('note', 'task')"),
      select("not_in_single", "kind NOT IN ('note')"),
      select("coalesce", "coalesce(app.team(), 'x') = 'x'"),
      select("nullif", "nullif(app.team(), 'x') = 'y'"),
      select("claims_text", "app.claims() ->> 'k' = 'v'"),
      select("claims_text_initplan", "(select app.claims() ->> 'k') = 'v'"),
      select("setting_text", "current_setting('app.claims', true)::jsonb ->> 'k' = 'v'"),
      select("setting_boolean", "(current_setting('app.claims', true)::jsonb ->> 'k')::boolean"),
      select("regex_case_sensitive", "app.team() ~ 'public:lobby'"),
      select("true", "true"),
      select("false", "false"),
      select("eq_null", "app.team() = NULL"),
      select("concat_null", "app.team() = 'x' || NULL"),
      select("and_in_or", "app.team() = 'a' OR (app.team() = 'b' AND kind = 'note')"),
      select("or_in_and", "(app.team() = 'a' OR app.team() = 'b') AND kind = 'note'"),
      select("and_three", "app.team() = 'a' AND kind = 'note' AND private = true"),
      select("doubled_quote", "app.team() = 'it''s'"),
      select("exists", "EXISTS (SELECT 1 FROM app.docs d2 WHERE d2.team = app.team())"),
      select("case_searched", "CASE WHEN kind = 'note' THEN true ELSE false END"),
      select("case_simple", "CASE kind WHEN 'note' THEN true ELSE false END"),
      select("user_role", "app.user_role() = 'member'"),
      select("private", "private = true"),
      select("title", "title = 'x'"),
      policy("grammar_all_using_only", "FOR ALL TO member USING (app.team() = 'x')"),
      policy("grammar_restrictive", "AS RESTRICTIVE FOR SELECT TO member USING (app.team() = 'x')"),
      policy("grammar_to_public", "FOR SELECT USING (app.team() = 'x')"),
      policy("grammar_to_guest_member", "FOR SELECT TO guest, member USING (app.team() = 'x')")
    ]
  end

  @doc """
  The statements of the typical policies, named `typical_<name>`, for the params that the fixtures
  use. The `broken_*` ones call `public.test_log_error()`, which `PolicyEval.Test.ExampleDatabase`
  creates.
  """
  @spec typical_statements() :: [String.t()]
  def typical_statements, do: typical_statements(@typical_names, @typical_params)

  @doc "The statements of the typical policies `names`, with `params`, named as in `typical_statements/0`."
  @spec typical_statements([atom()], map()) :: [String.t()]
  def typical_statements(names, params), do: Enum.map(names, &typical(&1, params))

  # Each policy is named typical_<name>, so that all of them can exist at the same time.
  defp typical(:member_read_all, _params) do
    """
    CREATE POLICY "typical_member_read_all"
    ON app.docs FOR SELECT
    TO member
    USING ( true );
    """
  end

  defp typical(:member_insert_all, _params) do
    """
    CREATE POLICY "typical_member_insert_all"
    ON app.docs FOR INSERT
    TO member
    WITH CHECK ( true );
    """
  end

  defp typical(:member_read_matching_user_id, %{user_id: user_id}) do
    """
    CREATE POLICY "typical_member_read_matching_user_id"
    ON app.docs FOR SELECT
    TO member
    USING (((SELECT app.user_id() AS user_id)::text) = '#{user_id}')
    """
  end

  defp typical(:read_matching_user_role, %{role: role}) do
    """
    CREATE POLICY "typical_read_matching_user_role"
    ON app.docs FOR SELECT
    USING (((SELECT app.user_role())::text) = '#{role}')
    """
  end

  defp typical(:member_write_matching_user_id, %{user_id: user_id}) do
    """
    CREATE POLICY "typical_member_write_matching_user_id"
    ON app.docs FOR INSERT
    TO member
    WITH CHECK (((SELECT app.user_id() AS user_id)::text) = '#{user_id}')
    """
  end

  defp typical(:write_matching_user_role, %{role: role}) do
    """
    CREATE POLICY "typical_write_matching_user_role"
    ON app.docs FOR INSERT
    WITH CHECK (((SELECT app.user_role())::text) = '#{role}')
    """
  end

  defp typical(:member_read_notes, %{team: team}) do
    """
    CREATE POLICY "typical_member_read_notes"
    ON app.docs FOR SELECT
    TO member
    USING ( app.team() = '#{team}' AND app.docs.kind = 'note' );
    """
  end

  defp typical(:member_write_notes, %{team: team}) do
    """
    CREATE POLICY "typical_member_write_notes"
    ON app.docs FOR INSERT
    TO member
    WITH CHECK ( app.team() = '#{team}' AND app.docs.kind = 'note');
    """
  end

  defp typical(:member_write_files, %{team: team}) do
    """
    CREATE POLICY "typical_member_write_files"
    ON app.docs FOR INSERT
    TO member
    WITH CHECK ( app.team() = '#{team}' AND app.docs.kind = 'file');
    """
  end

  defp typical(:member_read_tasks, %{team: team}) do
    """
    CREATE POLICY "typical_member_read_tasks"
    ON app.docs FOR SELECT
    TO member
    USING ( app.team() = '#{team}' AND app.docs.kind = 'task' );
    """
  end

  defp typical(:member_write_tasks, %{team: team}) do
    """
    CREATE POLICY "typical_member_write_tasks"
    ON app.docs FOR INSERT
    TO member
    WITH CHECK ( app.team() = '#{team}' AND app.docs.kind = 'task' );
    """
  end

  defp typical(:member_read_own_tasks, %{team: team, user_id: user_id}) do
    """
    CREATE POLICY "typical_member_read_own_tasks"
    ON app.docs FOR SELECT
    TO member
    USING (
      app.team() = '#{team}'
      AND app.docs.kind = 'task'
      AND ((SELECT app.user_id())::text) = '#{user_id}'
    );
    """
  end

  defp typical(:member_read_notes_and_tasks, %{team: team}) do
    """
    CREATE POLICY "typical_member_read_notes_and_tasks"
    ON app.docs FOR SELECT
    TO member
    USING ( app.team() = '#{team}' AND app.docs.kind IN ('task', 'note') );
    """
  end

  defp typical(:member_write_notes_and_tasks, %{team: team}) do
    """
    CREATE POLICY "typical_member_write_notes_and_tasks"
    ON app.docs FOR INSERT
    TO member
    WITH CHECK ( app.team() = '#{team}' AND app.docs.kind IN ('task', 'note') );
    """
  end

  defp typical(:member_read_tasks_by_claim, %{team: team}) do
    """
    CREATE POLICY "typical_member_read_tasks_by_claim"
    ON app.docs FOR SELECT
    TO member
    USING (
      app.team() = '#{team}'
      AND app.docs.kind = 'task'
      AND coalesce(((current_setting('app.claims', true))::jsonb ->> 'tasks_read')::boolean, false)
    );
    """
  end

  defp typical(:member_read_notes_by_claim, %{team: team}) do
    """
    CREATE POLICY "typical_member_read_notes_by_claim"
    ON app.docs FOR SELECT
    TO member
    USING (
      app.team() = '#{team}'
      AND app.docs.kind = 'note'
      AND coalesce(((current_setting('app.claims', true))::jsonb ->> 'notes_read')::boolean, false)
    );
    """
  end

  defp typical(:broken_read, _params) do
    """
    CREATE POLICY "typical_broken_read"
    ON app.docs FOR SELECT
    TO member
    USING (  (SELECT test_log_error())  );
    """
  end

  defp typical(:broken_write, _params) do
    """
    CREATE POLICY "typical_broken_write"
    ON app.docs FOR INSERT
    TO member
    WITH CHECK ( (SELECT test_log_error()) );
    """
  end

  defp typical(:slow_read, _params) do
    """
    CREATE POLICY "typical_slow_read"
    ON app.docs AS RESTRICTIVE FOR SELECT
    TO member
    USING ( (SELECT true FROM pg_sleep(1)) );
    """
  end

  defp typical(:slow_write, _params) do
    """
    CREATE POLICY "typical_slow_write"
    ON app.docs AS RESTRICTIVE FOR INSERT
    TO member
    WITH CHECK ( (SELECT true FROM pg_sleep(1)) );
    """
  end

  defp policy(name, definition), do: ~s(CREATE POLICY "#{name}" ON app.docs #{definition})

  defp select(name, using), do: policy("grammar_#{name}", "FOR SELECT TO member USING (#{using})")
end
