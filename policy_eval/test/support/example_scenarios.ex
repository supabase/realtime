defmodule PolicyEval.Test.ExampleScenarios do
  @moduledoc """
  The scenarios of Level 2 of the tests against Postgres (`test/postgres/decisions_test.exs`), for
  the example of `PolicyEval.Test.ExampleProfile`.

  A scenario is a set of policies on `app.docs`, an environment (the settings of a session, and
  the row), and the kinds it asks for. Each kind is asked for as a read and as a write, with the key
  `{operation, kind}`. Its `:meta` has what `PolicyEval.Test.Collector` reports.

  Some scenarios test the internals of the library, for example the decision table of the unit
  tests.
  """

  alias PolicyEval.Test.ExampleDatabase
  alias PolicyEval.Test.ExamplePolicies

  @own "c0ffee00-1111-4222-8333-444455556666"
  @other "deadbeef-0000-4000-8000-000000000001"

  # The kinds of document that the example checks, for reads and writes
  @kinds ["note", "task"]

  @headers ~s({"user-agent":"policy_eval"})

  @set_settings_query """
  SELECT set_config('role', $1, true),
         set_config('app.team', $2, true),
         set_config('app.claims', $3, true),
         set_config('app.user_id', $4, true),
         set_config('app.user_role', $5, true),
         set_config('app.headers', $6, true)
  """

  @doc "How the bodies of `app.user_id()` and `app.user_role()` are called in test names and in the report."
  @spec flavor_label(:simple | :fallback) :: String.t()
  def flavor_label(flavor) when flavor in [:simple, :fallback], do: Atom.to_string(flavor)

  ## The environment of a case: the settings of a session, and the row

  @doc """
  The environment of a case. `user_id`, `team` and `kind` are as the application sets them, and
  nil is NULL. `user_role` is the role in `app.user_role`, the role unless given. `claims` is the
  JSON text, built from the role and the user id unless given (as text, or as a map to encode).
  `extra_claims` are added to the built claims. The row has the team and the kind, unless
  `row_team` is given.
  """
  @spec env(keyword()) :: map()
  def env(opts) do
    role = Keyword.get(opts, :role, "member")
    team = Keyword.get(opts, :team, "room:1")
    user_id = Keyword.get(opts, :user_id, @own)

    claims =
      case Keyword.fetch(opts, :claims) do
        {:ok, claims} when is_map(claims) ->
          JSON.encode!(claims)

        {:ok, claims} ->
          claims

        :error ->
          %{"role" => role}
          |> then(&if user_id, do: Map.put(&1, "sub", user_id), else: &1)
          |> Map.merge(Keyword.get(opts, :extra_claims, %{}))
          |> JSON.encode!()
      end

    %{
      role: role,
      team: team,
      row_team: Keyword.get(opts, :row_team, team),
      kind: Keyword.get(opts, :kind, "note"),
      user_id: user_id,
      user_role: Keyword.get(opts, :user_role, role),
      claims: claims,
      headers: Keyword.get(opts, :headers, @headers)
    }
  end

  @doc "The `PolicyEval.Env` of an environment, for one kind."
  @spec policy_eval_env(map(), String.t()) :: PolicyEval.Env.t()
  def policy_eval_env(env, kind) do
    PolicyEval.Env.new(
      %{
        "role" => env.role,
        "app.team" => env.team,
        "app.claims" => env.claims,
        "app.user_id" => env.user_id,
        "app.user_role" => env.user_role,
        "app.headers" => env.headers
      },
      %{"team" => text(env.row_team), "kind" => text(kind)}
    )
  end

  defp text(nil), do: nil
  defp text(value), do: {:text, value}

  @doc """
  Sets the settings of an environment in the transaction of `conn`, as the application does before
  a query. This also switches to the role.
  """
  @spec set_settings!(DBConnection.t(), map()) :: Postgrex.Result.t()
  def set_settings!(conn, env) do
    Postgrex.query!(conn, @set_settings_query, [env.role, env.team, env.claims, env.user_id, env.user_role, env.headers])
  end

  @doc "An environment, for the failure output."
  @spec describe_env(map(), String.t() | nil) :: String.t()
  def describe_env(env, kind) do
    """
        role=#{inspect(env.role)} team=#{inspect(env.team)} row=#{inspect({env.row_team, kind})}
        user_id=#{inspect(env.user_id)} user_role=#{inspect(env.user_role)}
        claims=#{inspect(env.claims)}\
    """
  end

  ## Scenarios

  # name, group and the options of a scenario:
  #   policies:   CREATE POLICY statements, run after the ones that are on the table are dropped
  #   setup:      statements run before them
  #   env:        see env/1
  #   functions:  :simple | :fallback, the bodies of app.user_id() and app.user_role()
  #   kinds:      what is asked for, both as read and write kinds
  #   table:      %{{:read | :write, kind} => decision} the unit tests of policy_eval expect
  #   personal_teams: :grid | :table | :planner, for the personal-team sections of the report
  #   meta:       more for the report
  defp scenario(group, name, policies, env_opts, opts \\ []) do
    env = env(env_opts)
    functions = Keyword.get(opts, :functions, :simple)
    kinds = Keyword.get(opts, :kinds, @kinds)

    %{
      group: group,
      name: name,
      setup: functions_setup(functions) ++ Keyword.get(opts, :setup, []),
      policies: policies,
      questions:
        for(
          operation <- [:read, :write],
          kind <- kinds,
          do: {{operation, kind}, operation, policy_eval_env(env, kind)}
        ),
      detail: "functions: #{flavor_label(functions)}",
      env: env,
      kinds: kinds,
      meta:
        Map.merge(Keyword.get(opts, :meta, %{}), %{
          role: env.role,
          flavor: functions,
          table: Keyword.get(opts, :table, %{}),
          personal_teams: Keyword.get(opts, :personal_teams)
        })
    }
  end

  # The database has the simple bodies, see PolicyEval.Test.ExampleDatabase
  defp functions_setup(:simple), do: []
  defp functions_setup(:fallback), do: [ExampleDatabase.fallback_functions_statement()]

  defp policy_sql(name, definition), do: ~s(CREATE POLICY "#{name}" ON app.docs #{definition})

  ## The decision table of the unit tests (test/policy_eval/policy_set_test.exs, "personal teams"),
  ## with what they expect. Copied, so that Postgres can check the expectations.

  @uid "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @other_uid "b1ffcd00-8d1c-4ff9-cc7e-7cc0ce491b22"

  @invalid_uuid {:fallback,
                 {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type uuid"}}}
  @regex_non_ascii {:fallback, {:unsupported, :regex_non_ascii}}

  @personal_team_reads [
    %{name: "own user id", team: "user:#{@uid}", user_id: @uid, expect: :allow},
    %{name: "someone else's user id", team: "user:#{@other_uid}", user_id: @uid, expect: :deny},
    %{name: "own user id in upper case", team: "user:#{String.upcase(@uid)}", user_id: @uid, expect: :deny},
    %{name: "the lobby team", team: "public:lobby", user_id: @uid, expect: :allow},
    %{name: "the lobby team in upper case", team: "PUBLIC:LOBBY", user_id: @uid, expect: :allow},
    %{name: "the lobby team inside another one", team: "xpublic:lobbyy", user_id: @uid, expect: :allow},
    %{name: "a team that matches nothing", team: "room:1", user_id: @uid, expect: :deny},
    %{name: "a non-ASCII team", team: "public:lobby:é", user_id: @uid, expect: @regex_non_ascii},
    %{name: "a non-ASCII team that can't match", team: "café", user_id: @uid, expect: @regex_non_ascii},
    %{name: "an empty team", team: "", user_id: @uid, expect: :deny},
    %{name: "user id in upper case", team: "user:#{@uid}", user_id: String.upcase(@uid), expect: :allow},
    %{name: "braced user id", team: "user:#{@uid}", user_id: "{#{@uid}}", expect: :allow},
    %{name: "unhyphenated user id", team: "user:#{@uid}", user_id: String.replace(@uid, "-", ""), expect: :allow},
    %{
      name: "user id with hyphens after every group",
      team: "user:#{@uid}",
      user_id: "a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11",
      expect: :allow
    },
    %{name: "user id with a leading space", team: "user:#{@uid}", user_id: " #{@uid}", expect: @invalid_uuid},
    %{name: "empty user id", team: "user:#{@uid}", user_id: "", expect: :deny, fallback: @invalid_uuid},
    %{name: "no user id", team: "user:#{@uid}", user_id: nil, expect: :deny},
    %{name: "no user id on the lobby team", team: "public:lobby", user_id: nil, expect: :allow},
    %{name: "user id that isn't a uuid", team: "user:user_2abc", user_id: "user_2abc", expect: @invalid_uuid},
    %{
      name: "user id that isn't a uuid, on a team nothing matches",
      team: "room:1",
      user_id: "user_2abc",
      expect: @invalid_uuid
    },
    %{
      name: "user id that isn't a uuid, on the lobby team",
      team: "public:lobby",
      user_id: "user_2abc",
      expect: @invalid_uuid
    },
    %{name: "guest, own user id", team: "user:#{@uid}", user_id: @uid, role: "guest", expect: :deny},
    %{name: "guest, the lobby team", team: "public:lobby", user_id: @uid, role: "guest", expect: :deny},
    %{
      name: "admin",
      team: "user:#{@uid}",
      user_id: @uid,
      role: "admin",
      expect: {:fallback, {:role, "admin"}}
    },
    # "a kind outside the list", with the kind of the read of that test
    %{
      name: "a kind outside the list, own user id",
      team: "user:#{@uid}",
      user_id: @uid,
      kinds: ["comment"],
      expect: :deny
    },
    %{
      name: "a kind outside the list, user id that isn't a uuid",
      team: "user:user_2abc",
      user_id: "user_2abc",
      kinds: ["comment"],
      expect: @invalid_uuid
    }
  ]

  @personal_team_writes [
    %{name: "own user id", team: "user:#{@uid}", user_id: @uid, expect: :allow},
    %{name: "someone else's user id", team: "user:#{@other_uid}", user_id: @uid, expect: :deny},
    %{name: "own user id in upper case", team: "user:#{String.upcase(@uid)}", user_id: @uid, expect: :deny},
    %{name: "the lobby team", team: "public:lobby", user_id: @uid, expect: :deny},
    %{name: "the lobby team in upper case", team: "PUBLIC:LOBBY", user_id: @uid, expect: :deny},
    %{name: "the lobby team inside another one", team: "xpublic:lobbyy", user_id: @uid, expect: :deny},
    %{name: "a non-ASCII team", team: "public:lobby:é", user_id: @uid, expect: :deny},
    %{name: "an empty team", team: "", user_id: @uid, expect: :deny},
    %{name: "user id in upper case", team: "user:#{@uid}", user_id: String.upcase(@uid), expect: :allow},
    %{name: "braced user id", team: "user:#{@uid}", user_id: "{#{@uid}}", expect: :allow},
    %{name: "unhyphenated user id", team: "user:#{@uid}", user_id: String.replace(@uid, "-", ""), expect: :allow},
    %{name: "empty user id", team: "user:#{@uid}", user_id: "", expect: :deny, fallback: @invalid_uuid},
    %{name: "no user id", team: "user:#{@uid}", user_id: nil, expect: :deny},
    %{name: "user id that isn't a uuid", team: "user:user_2abc", user_id: "user_2abc", expect: @invalid_uuid},
    %{
      name: "user id that isn't a uuid, on the lobby team",
      team: "public:lobby",
      user_id: "user_2abc",
      expect: @invalid_uuid
    },
    %{name: "guest, own user id", team: "user:#{@uid}", user_id: @uid, role: "guest", expect: :deny},
    %{
      name: "admin",
      team: "user:#{@uid}",
      user_id: @uid,
      role: "admin",
      expect: {:fallback, {:role, "admin"}}
    },
    %{name: "own user id, task", team: "user:#{@uid}", user_id: @uid, kinds: ["task"], expect: :allow},
    %{
      name: "own user id, a kind outside the list",
      team: "user:#{@uid}",
      user_id: @uid,
      kinds: ["file"],
      expect: :deny
    },
    %{
      name: "user id that isn't a uuid, a kind outside the list",
      team: "user:user_2abc",
      user_id: "user_2abc",
      kinds: ["file"],
      expect: @invalid_uuid
    }
  ]

  # What the user ids of the personal-team grid are: a spelling of a uuid, or not
  defp user_id_kind(nil), do: :missing
  defp user_id_kind(""), do: :empty
  defp user_id_kind("user_2abc"), do: :not_a_uuid
  defp user_id_kind(_uuid), do: :valid_uuid

  @doc """
  Personal teams. The teams are for a user whose id is the own uuid, and the user ids are spellings
  of it.
  """
  @spec personal_team_grid(:plain | :initplan, :simple | :fallback) :: [map()]
  def personal_team_grid(form, flavor) do
    policies = ExamplePolicies.personal_team_policies(form)

    teams = [
      {"own user id", "user:#{@own}"},
      {"other user id", "user:#{@other}"},
      {"own user id in upper case", "user:#{String.upcase(@own)}"},
      {"lobby", "public:lobby"},
      {"lobby in upper case", "PUBLIC:LOBBY"},
      {"lobby inside another team", "xpublic:lobbyy"},
      {"non-ASCII", "public:lobby:é"},
      {"non-ASCII, matches nothing", "café"},
      {"empty", ""},
      {"user: and nothing", "user:"},
      {"room", "room:1"}
    ]

    user_ids = [
      {"canonical", @own},
      {"upper case", String.upcase(@own)},
      {"braced", "{#{@own}}"},
      {"unhyphenated", String.replace(@own, "-", "")},
      {"empty", ""},
      {"missing", nil},
      {"not a uuid", "user_2abc"},
      {"another uuid", @other}
    ]

    full =
      for {team_label, team} <- teams, {user_id_label, user_id} <- user_ids do
        {"member", team_label, team, user_id_label, user_id, []}
      end

    # No policy is for these, so only a few combinations
    other_roles =
      for role <- ["guest", "admin"],
          {team_label, team} <- [{"own user id", "user:#{@own}"}, {"lobby", "public:lobby"}, {"empty", ""}],
          {user_id_label, user_id} <- [{"canonical", @own}, {"missing", nil}, {"not a uuid", "user_2abc"}] do
        {role, team_label, team, user_id_label, user_id, []}
      end

    # Claims that jsonb doesn't take as they are. The fallback app.user_id() reads them when the user id is empty
    claim_variants = [
      {"NUL in a claim", [extra_claims: %{"note" => "a" <> <<0>> <> "b"}]},
      {"nested and numeric claims", [extra_claims: %{"n" => 1.5, "m" => %{"a" => [1, nil]}, "t" => true}]},
      {"duplicate sub in the claims", [claims: ~s({"role":"member","sub":"#{@other}","sub":"#{@own}"})]}
    ]

    claims =
      for {claims_label, claim_opts} <- claim_variants,
          {team_label, team} <- [{"own user id", "user:#{@own}"}, {"lobby", "public:lobby"}],
          {user_id_label, user_id} <- [{"canonical", @own}, {"missing", nil}, {"empty", ""}] do
        {"member", team_label, team, "#{user_id_label}, #{claims_label}", user_id, claim_opts}
      end

    for {role, team_label, team, user_id_label, user_id, claim_opts} <- full ++ other_roles ++ claims do
      scenario(
        "personal teams #{form}, #{flavor_label(flavor)}",
        "personal teams #{form} (#{flavor_label(flavor)}) #{role}, team: #{team_label}, user id: #{user_id_label}",
        policies,
        Keyword.merge([role: role, team: team, user_id: user_id], claim_opts),
        functions: flavor,
        meta: %{
          team: team_label,
          user_id: user_id_label,
          user_id_kind: user_id_kind(user_id),
          ascii_team: byte_size(team) == String.length(team)
        },
        personal_teams: :grid
      )
    end
  end

  @doc """
  The table of the unit tests, for both bodies of `app.user_id()`, against all five policies, and
  the cases that the unit tests say depend on the order the planner puts the clauses in: the cast
  of a user id that isn't a uuid is only reached if `kind IN (...)` doesn't come first. What
  Postgres does depends on the policies that exist, so they are asked for plain, initplan and both.
  """
  @spec personal_team_table_scenarios() :: [map()]
  def personal_team_table_scenarios do
    policies = ExamplePolicies.personal_team_policies()

    planner_order =
      for {label, policies} <- [
            {"plain", ExamplePolicies.personal_team_policies(:plain)},
            {"initplan", ExamplePolicies.personal_team_policies(:initplan)},
            {"plain and initplan", policies}
          ],
          flavor <- [:simple, :fallback],
          team <- ["user:user_2abc", "public:lobby"] do
        scenario(
          "personal teams planner order",
          "personal teams #{label} policies, #{flavor_label(flavor)}, team #{team}, user id user_2abc, kinds outside the list",
          policies,
          [team: team, user_id: "user_2abc"],
          functions: flavor,
          kinds: ["file", "comment"],
          meta: %{policies: label, flavor: flavor, team: team},
          personal_teams: :planner
        )
      end

    table =
      for {operation, rows} <- [read: @personal_team_reads, write: @personal_team_writes],
          row <- rows,
          flavor <- [:simple, :fallback] do
        kinds = Map.get(row, :kinds, @kinds)

        expect =
          if flavor == :fallback and Map.has_key?(row, :fallback), do: row.fallback, else: row.expect

        scenario(
          "personal teams table, #{flavor_label(flavor)}",
          "personal teams table #{operation}: #{row.name} (#{flavor_label(flavor)})",
          policies,
          [role: Map.get(row, :role, "member"), team: row.team, user_id: row.user_id],
          functions: flavor,
          kinds: kinds,
          table: Map.new(kinds, &{{operation, &1}, expect}),
          personal_teams: :table
        )
      end

    table ++ planner_order
  end

  @doc "The typical policies, see `PolicyEval.Test.ExamplePolicies`."
  @spec typical_scenarios() :: [map()]
  def typical_scenarios do
    typical = fn names, params -> ExamplePolicies.typical_statements(names, params) end

    # OR REPLACE: the database can have it already
    broken_setup = [
      "CREATE OR REPLACE FUNCTION public.test_log_error() RETURNS boolean AS $$ BEGIN RAISE EXCEPTION 'test error'; END $$ LANGUAGE plpgsql"
    ]

    team_specific =
      for {label, names} <- [
            {"notes", [:member_read_notes, :member_write_notes]},
            {"tasks", [:member_read_tasks, :member_write_tasks]},
            {"notes and tasks", [:member_read_notes_and_tasks, :member_write_notes_and_tasks]},
            {"notes and tasks, each",
             [
               :member_read_notes,
               :member_read_tasks,
               :member_write_notes,
               :member_write_tasks
             ]},
            {"write files", [:member_write_files, :member_write_notes]}
          ],
          role <- ["member", "guest"],
          team <- ["t1", "t2", "", "T1", "t1 "] do
        scenario("typical", "#{label}, #{role}, team #{inspect(team)}", typical.(names, %{team: "t1"}),
          role: role,
          team: team
        )
      end

    own_tasks =
      for user_id <- [@own, @other, String.upcase(@own), "{#{@own}}", nil, "", "user_2abc"],
          team <- ["t1", "t2"],
          flavor <- [:simple, :fallback] do
        scenario(
          "typical",
          "own tasks, user id #{inspect(user_id)}, team #{team} (#{flavor_label(flavor)})",
          typical.([:member_read_own_tasks], %{team: "t1", user_id: @own}),
          [team: team, user_id: user_id],
          functions: flavor
        )
      end

    claim_policies =
      typical.(
        [:member_read_notes_by_claim, :member_read_tasks_by_claim],
        %{team: "t1"}
      )

    claims =
      for {label, json} <- [
            {"true", ~s({"notes_read":true,"tasks_read":true})},
            {"false", ~s({"notes_read":false,"tasks_read":false})},
            {"missing", ~s({"role":"member"})},
            {"strings", ~s({"notes_read":"true","tasks_read":"yes"})},
            {"string 0", ~s({"notes_read":"0","tasks_read":"off"})},
            {"null", ~s({"notes_read":null,"tasks_read":null})},
            {"mixed", ~s({"notes_read":true,"tasks_read":false})},
            {"maybe", ~s({"notes_read":"maybe","tasks_read":"maybe"})},
            {"one maybe", ~s({"notes_read":true,"tasks_read":"maybe"})},
            {"numbers", ~s({"notes_read":1,"tasks_read":0})},
            {"objects", ~s({"notes_read":{"a":1},"tasks_read":[]})},
            {"duplicate keys", ~s({"notes_read":false,"notes_read":true,"tasks_read":true,"tasks_read":false})},
            {"array root", ~s(["notes_read"])},
            {"string root", ~s("notes_read")},
            {"empty object", "{}"},
            {"NUL escape", ~s({"notes_read":"\\u0000","tasks_read":true})},
            {"NUL escape elsewhere", ~s({"x":"\\u0000","notes_read":true})},
            {"not json", "not json"},
            {"empty claims", ""}
          ],
          team <- ["t1", "t2"] do
        scenario("typical", "claims #{label}, team #{team}", claim_policies, team: team, claims: json)
      end

    matching_user_id =
      for user_id <- [
            @own,
            @other,
            String.upcase(@own),
            "{#{@own}}",
            String.replace(@own, "-", ""),
            nil,
            "",
            "user_2abc"
          ],
          flavor <- [:simple, :fallback] do
        scenario(
          "typical",
          "matching user id, user id #{inspect(user_id)} (#{flavor_label(flavor)})",
          typical.([:member_read_matching_user_id, :member_write_matching_user_id], %{user_id: @own}),
          [user_id: user_id],
          functions: flavor
        )
      end

    matching_role =
      for role <- ["member", "guest", "admin"], flavor <- [:simple, :fallback] do
        scenario(
          "typical",
          "matching user role, #{role} (#{flavor_label(flavor)})",
          typical.([:read_matching_user_role, :write_matching_user_role], %{role: "member"}),
          [role: role],
          functions: flavor
        )
      end

    everything =
      for role <- ["member", "guest"], team <- ["t1", ""] do
        scenario(
          "typical",
          "all teams, #{role}, team #{inspect(team)}",
          typical.([:member_read_all, :member_insert_all], %{}),
          role: role,
          team: team
        )
      end

    # A policy that raises. One of them next to a policy that is true: Postgres evaluates the
    # permissive ones in reverse name order (so the failing one first) but folds `x OR true`.
    broken =
      for {label, names} <- [
            {"alone", [:broken_read, :broken_write]},
            {"with a true policy", [:broken_read, :broken_write, :member_read_all, :member_insert_all]}
          ] do
        scenario("typical", "broken policies #{label}", typical.(names, %{}), [], setup: broken_setup)
      end

    team_specific ++ own_tasks ++ claims ++ matching_user_id ++ matching_role ++ everything ++ broken
  end

  @doc "How policies combine: permissive and restrictive, commands, roles, NULL, and what the library does not model."
  @spec combination_scenarios() :: [map()]
  def combination_scenarios do
    is_x = "app.team() = 'x'"
    is_y = "app.team() = 'y'"

    sets = [
      {"permissive policies are OR'd",
       [
         policy_sql("a", "FOR SELECT TO member USING (#{is_x})"),
         policy_sql("b", "FOR SELECT TO member USING (#{is_y})"),
         policy_sql("c", "FOR INSERT TO member WITH CHECK (#{is_x})"),
         policy_sql("d", "FOR INSERT TO member WITH CHECK (#{is_y})")
       ]},
      {"restrictive next to a permissive policy",
       [
         policy_sql("a", "FOR SELECT TO member USING (true)"),
         policy_sql("r1", "AS RESTRICTIVE FOR SELECT TO member USING (app.team() <> 'x')"),
         policy_sql("r2", "AS RESTRICTIVE FOR SELECT TO member USING (app.team() <> 'y')"),
         policy_sql("c", "FOR INSERT TO member WITH CHECK (true)"),
         policy_sql("r3", "AS RESTRICTIVE FOR INSERT TO member WITH CHECK (app.team() <> 'x')")
       ]},
      {"restrictive policies alone",
       [
         policy_sql("r1", "AS RESTRICTIVE FOR SELECT TO member USING (true)"),
         policy_sql("r2", "AS RESTRICTIVE FOR INSERT TO member WITH CHECK (true)")
       ]},
      {"no policy", []},
      {"NULL",
       [
         policy_sql("a", "FOR SELECT TO member USING (app.team() = NULL)"),
         policy_sql("b", "FOR INSERT TO member WITH CHECK (app.team() = NULL)")
       ]},
      {"NULL next to a true policy",
       [
         policy_sql("a", "FOR SELECT TO member USING (app.team() = NULL)"),
         policy_sql("b", "FOR SELECT TO member USING (#{is_x})"),
         policy_sql("c", "FOR INSERT TO member WITH CHECK (app.team() = NULL)"),
         policy_sql("d", "FOR INSERT TO member WITH CHECK (#{is_x})")
       ]},
      {"NULL in a restrictive policy",
       [
         policy_sql("a", "FOR SELECT TO member USING (true)"),
         policy_sql("r", "AS RESTRICTIVE FOR SELECT TO member USING (kind = NULL)"),
         policy_sql("c", "FOR INSERT TO member WITH CHECK (true)"),
         policy_sql("s", "AS RESTRICTIVE FOR INSERT TO member WITH CHECK (kind = NULL)")
       ]},
      {"FOR ALL with USING only", [policy_sql("a", "FOR ALL TO member USING (#{is_x})")]},
      {"FOR ALL with USING and WITH CHECK",
       [policy_sql("a", "FOR ALL TO member USING (#{is_x}) WITH CHECK (#{is_y})")]},
      {"FOR INSERT only", [policy_sql("a", "FOR INSERT TO member WITH CHECK (#{is_x})")]},
      {"FOR SELECT only", [policy_sql("a", "FOR SELECT TO member USING (#{is_x})")]},
      {"UPDATE and DELETE policies",
       [
         policy_sql("a", "FOR UPDATE TO member USING (true) WITH CHECK (true)"),
         policy_sql("b", "FOR DELETE TO member USING (true)")
       ]},
      {"a policy for guest", [policy_sql("a", "FOR ALL TO guest USING (true)")]},
      {"a policy for public", [policy_sql("a", "FOR ALL USING (#{is_x})")]},
      {"a policy for guest and member", [policy_sql("a", "FOR ALL TO guest, member USING (#{is_x})")]},
      {"a policy for admin", [policy_sql("a", "FOR ALL TO admin USING (true)")]},
      {"a restrictive policy for another role",
       [
         policy_sql("a", "FOR ALL TO member, guest USING (true)"),
         policy_sql("r", "AS RESTRICTIVE FOR ALL TO guest USING (false)")
       ]},
      {"a mix of cmd for one name",
       [
         policy_sql("a", "FOR SELECT TO member USING (true)"),
         policy_sql("b", "FOR ALL TO member USING (false) WITH CHECK (true)")
       ]},
      {"the kind",
       [
         policy_sql("a", "FOR ALL TO member USING (kind = 'note')"),
         policy_sql("b", "FOR ALL TO member USING (kind = 'task' AND #{is_x})")
       ]},
      {"unsupported next to a decisive policy",
       [
         policy_sql("a", "FOR ALL TO member USING (lower(app.team()) = 'x')"),
         policy_sql("b", "FOR ALL TO member USING (#{is_x})")
       ]},
      {"unsupported alone", [policy_sql("a", "FOR ALL TO member USING (lower(app.team()) = 'x')")]},
      {"a failing restrictive policy next to an unsupported one",
       [
         policy_sql("a", "FOR ALL TO member USING (lower(app.team()) = 'x')"),
         policy_sql("r", "AS RESTRICTIVE FOR ALL TO member USING (#{is_y})")
       ]},
      {"unsupported restrictive policy",
       [
         policy_sql("a", "FOR ALL TO member USING (#{is_x})"),
         policy_sql("r", "AS RESTRICTIVE FOR ALL TO member USING (lower(app.team()) = 'x')")
       ]},
      {"a boolean test the parser doesn't read",
       [policy_sql("a", "FOR ALL TO member USING ((app.team() = 'x') IS NOT FALSE)")]},
      # The probe row has the defaults of the other columns, which aren't modelled
      {"another column", [policy_sql("a", "FOR ALL TO member USING (private = false)")]},
      {"another column or the team", [policy_sql("a", "FOR ALL TO member USING (title IS NULL OR app.team() = 'x')")]},
      {"another column and the team",
       [policy_sql("a", "FOR ALL TO member USING (title IS NOT NULL AND app.team() = 'x')")]},
      {"a function the snapshot doesn't have", [policy_sql("a", "FOR ALL TO member USING (app.email() IS NULL)")]}
    ]

    for {label, policies} <- sets, role <- ["member", "guest"], team <- ["x", "y", "z", ""] do
      scenario("combination", "#{label}, #{role}, team #{inspect(team)}", policies, role: role, team: team)
    end
  end

  @doc """
  Everything the library doesn't model has to be a fallback, not an answer. The setups change the
  database in the transaction of the scenario, and roll back with it.
  """
  @spec snapshot_scenarios(pos_integer()) :: [map()]
  def snapshot_scenarios(server_version_num) do
    policies = [
      policy_sql("a", "FOR SELECT TO member, guest USING (app.team() = 'x')"),
      policy_sql("b", "FOR INSERT TO member, guest WITH CHECK (app.team() = 'x')")
    ]

    setups = [
      {"baseline", []},
      {"RLS disabled", ["ALTER TABLE app.docs DISABLE ROW LEVEL SECURITY"]},
      {"RLS forced", ["ALTER TABLE app.docs FORCE ROW LEVEL SECURITY"]},
      {"no INSERT for member", ["REVOKE INSERT ON app.docs FROM member"]},
      {"no INSERT for guest", ["REVOKE INSERT ON app.docs FROM guest"]},
      {"member bypasses RLS", ["ALTER ROLE member BYPASSRLS"]},
      {"guest bypasses RLS", ["ALTER ROLE guest BYPASSRLS"]},
      {"a policy for a role member is a member of",
       [
         "CREATE ROLE policy_eval_team NOLOGIN",
         "GRANT policy_eval_team TO member",
         policy_sql("team", "FOR ALL TO policy_eval_team USING (true) WITH CHECK (true)")
       ]},
      {"a policy for a role member is not a member of",
       [
         "CREATE ROLE policy_eval_team NOLOGIN",
         policy_sql("team", "FOR ALL TO policy_eval_team USING (true) WITH CHECK (true)")
       ]}
    ]

    # GRANT ... WITH INHERIT is PG16 syntax
    setups =
      if server_version_num >= 160_000 do
        setups ++
          [
            {"a policy for a role member is a member of, without inheritance",
             [
               "CREATE ROLE policy_eval_team NOLOGIN",
               "GRANT policy_eval_team TO member WITH INHERIT FALSE",
               policy_sql("team", "FOR ALL TO policy_eval_team USING (true) WITH CHECK (true)")
             ]}
          ]
      else
        setups
      end

    for {label, setup} <- setups, role <- ["member", "guest", "admin"], team <- ["x", "y"] do
      {extra_policies, setup} = Enum.split_with(setup, &String.starts_with?(&1, "CREATE POLICY"))

      scenario(
        "snapshot",
        "#{label}, #{role}, team #{inspect(team)}",
        policies ++ extra_policies,
        [role: role, team: team],
        setup: setup
      )
    end
  end

  @doc """
  A write is a plain INSERT, so the SELECT privilege and the SELECT policies don't change it, see
  `PolicyEval.PolicySet`. Each scenario has an INSERT policy, and a SELECT setup that makes a
  SELECT of the table fail even when it reads no rows: a missing SELECT privilege, or a SELECT
  policy that Postgres can't plan. A read can raise, and a write still gets the answer of the
  INSERT policy.
  """
  @spec write_ignores_select_scenarios() :: [map()]
  def write_ignores_select_scenarios do
    insert_policy = policy_sql("insert", "FOR INSERT TO member, guest WITH CHECK (app.team() = 'x')")

    revokes = [
      {"no SELECT for member", ["REVOKE SELECT ON app.docs FROM member"]},
      {"no SELECT for guest", ["REVOKE SELECT ON app.docs FROM guest"]},
      {"a column privilege only",
       [
         "REVOKE SELECT ON app.docs FROM member",
         "GRANT SELECT (id) ON app.docs TO member"
       ]}
    ]

    from_revokes =
      for {label, setup} <- revokes, role <- ["member", "guest"], team <- ["x", "y"] do
        scenario(
          "write ignores select",
          "#{label}, #{role}, team #{inspect(team)}",
          [policy_sql("select", "FOR SELECT TO member, guest USING (app.team() = 'x')"), insert_policy],
          [role: role, team: team],
          setup: setup
        )
      end

    # A SELECT policy that fails in a way that doesn't need a row: when it is expanded, or evaluated at plan time
    select_policies = [
      {"a policy that reads the table", "EXISTS (SELECT 1 FROM app.docs d2 WHERE d2.team = app.team())"},
      {"a policy that divides by zero", "1 / 0 = 1"},
      {"a policy with a constant that raises", "('x' || '')::int = 1"},
      {"a policy that raises for this user id", "(app.user_id())::text = 'x'"},
      {"a policy that raises for this user id, and a true one", "(app.user_id())::text = 'x' OR true"},
      {"a policy that raises for this claim", "(app.claims() ->> 'n')::int > 0"},
      # A column against something stable that raises: the planner evaluates that when it estimates the
      # selectivity, so it may raise while planning, with the policy fully modelled
      {"a column against a stable expression that raises for this user id", "kind = (app.user_id())::text"},
      {"a column against a stable expression that raises for this user id, concatenated",
       "team = 'user:' || (app.user_id())::text"},
      {"a column against a stable expression that raises for this claim",
       "kind = ((app.claims() ->> 'n')::boolean)::text"}
    ]

    from_policies =
      for {label, qual} <- select_policies, role <- ["member", "guest"], user_id <- [@own, "user_2abc"] do
        scenario(
          "write ignores select",
          "#{label}, #{role}, user id #{inspect(user_id)}",
          [policy_sql("select", "FOR SELECT TO member, guest USING (#{qual})"), insert_policy],
          role: role,
          team: "x",
          user_id: user_id,
          extra_claims: %{"n" => "x"}
        )
      end

    from_revokes ++ from_policies
  end

  @doc """
  Policies that read nested claims with `->`: a field of an object, and the first and the last
  element of an array. Two more policies read the first and the last element with `->>`. Each
  policy compares a claim with the team of the row.
  """
  @spec nested_claim_scenarios() :: [map()]
  def nested_claim_scenarios do
    policies = [
      policy_sql("read by the team in app_metadata", """
      FOR SELECT TO member USING (team = app.claims() -> 'app_metadata' ->> 'team')
      """),
      policy_sql("read by the first team", """
      FOR SELECT TO member USING (team = app.claims() -> 'teams' -> 0 ->> 'id')
      """),
      policy_sql("write notes by the last team", """
      FOR INSERT TO member WITH CHECK (team = app.claims() -> 'teams' -> -1 ->> 'id' AND kind = 'note')
      """),
      policy_sql("read by the first team id", """
      FOR SELECT TO member USING (team = app.claims() -> 'team_ids' ->> 0)
      """),
      policy_sql("write notes by the last team id", """
      FOR INSERT TO member WITH CHECK (team = app.claims() -> 'team_ids' ->> -1 AND kind = 'note')
      """)
    ]

    claims = [
      {"the team in app_metadata", ~s({"app_metadata":{"team":"x"}})},
      {"another team in app_metadata", ~s({"app_metadata":{"team":"y"}})},
      {"app_metadata without a team", ~s({"app_metadata":{}})},
      {"app_metadata is null", ~s({"app_metadata":null})},
      {"app_metadata is a string", ~s({"app_metadata":"x"})},
      {"a team that is null", ~s({"app_metadata":{"team":null}})},
      {"a team that is a number", ~s({"app_metadata":{"team":1}})},
      {"a team that is an object", ~s({"app_metadata":{"team":{"id":"x"}}})},
      {"duplicate app_metadata, the last wins", ~s({"app_metadata":{"team":"y"},"app_metadata":{"team":"x"}})},
      {"teams, the team first", ~s({"teams":[{"id":"x"},{"id":"y"}]})},
      {"teams, the team last", ~s({"teams":[{"id":"y"},{"id":"x"}]})},
      {"one team", ~s({"teams":[{"id":"x"}]})},
      {"no teams", ~s({"teams":[]})},
      {"teams is an object", ~s({"teams":{"id":"x"}})},
      {"teams is a string", ~s({"teams":"x"})},
      {"a team in teams that is a number", ~s({"teams":[{"id":1},{"id":"x"}]})},
      {"both", ~s({"app_metadata":{"team":"x"},"teams":[{"id":"x"}]})},
      {"team ids, the team first", ~s({"team_ids":["x","y"]})},
      {"team ids, the team last", ~s({"team_ids":["y","x"]})},
      {"team ids, null first", ~s({"team_ids":[null,"x"]})},
      {"team ids, a number last", ~s({"team_ids":["x",1]})},
      {"team ids, an array first", ~s({"team_ids":[["x"],"x"]})},
      {"no team ids", ~s({"team_ids":[]})},
      {"team ids is a string", ~s({"team_ids":"x"})},
      {"team ids is an object", ~s({"team_ids":{"0":"x"}})},
      {"NUL escape in the team", ~s({"app_metadata":{"team":"\\u0000"}})},
      {"empty object", "{}"},
      {"array root", ~s([{"teams":[{"id":"x"}]}])},
      {"not json", "not json"},
      {"empty claims", ""}
    ]

    for {label, json} <- claims, team <- ["x", "y"] do
      scenario("nested claims", "#{label}, team #{team}", policies, team: team, claims: json)
    end
  end

  @doc """
  A policy that raises next to one that allows. The permissive policies are evaluated in reverse
  name order, so b_raises before a_allow. Whether that makes the call raise depends on what
  Postgres does with `b_raises OR a_allow` before it runs. The library can't tell, so it has to
  fall back where Postgres raises, whatever the other policy says: a decided answer there is a
  mismatch.
  """
  @spec raising_policy_scenarios() :: [map()]
  def raising_policy_scenarios do
    raising_policies = fn raises, allow ->
      [
        policy_sql("a_allow", "FOR SELECT TO member USING (#{allow})"),
        policy_sql("b_raises", "FOR SELECT TO member USING (#{raises})"),
        policy_sql("c_allow", "FOR INSERT TO member WITH CHECK (#{allow})"),
        policy_sql("d_raises", "FOR INSERT TO member WITH CHECK (#{raises})")
      ]
    end

    cast_raises = "(app.claims() ->> 'n')::int > 0"
    user_id_raises = "(app.user_id())::text = 'x'"

    for {label, raises, allow, env_opts} <- [
          # `b OR true` is simplified to true before anything runs, so Postgres never evaluates what raises
          {"int cast of a claim, a policy that is constant true", cast_raises, "true", [extra_claims: %{"n" => "x"}]},
          {"user id cast, a policy that is constant true", user_id_raises, "true", [user_id: "user_2abc"]},
          # A policy that isn't constant is where the failing one runs first and raises
          {"int cast of a claim, a policy on the kind", cast_raises, "kind = 'note'", [extra_claims: %{"n" => "x"}]},
          {"user id cast, a policy on the kind", user_id_raises, "kind = 'note'", [user_id: "user_2abc"]},
          {"user id cast, a policy on the team", user_id_raises, "app.team() = 'room:1'", [user_id: "user_2abc"]},
          {"int cast of a claim, a policy on the team", cast_raises, "app.team() = 'room:1'",
           [extra_claims: %{"n" => "x"}]}
        ] do
      scenario("raising policies", label, raising_policies.(raises, allow), env_opts)
    end
  end
end
