defmodule PolicyEval.PolicySetTest do
  use ExUnit.Case, async: true

  alias PolicyEval.Env
  alias PolicyEval.Policy
  alias PolicyEval.Snapshot
  alias PolicyEval.Test.ExampleProfile

  @profile ExampleProfile.profile()

  @versions ["pg17", "pg15"]

  @uid "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @other_uid "b1ffcd00-8d1c-4ff9-cc7e-7cc0ce491b22"

  @roles %{
    "guest" => %{bypass_rls: false, select: true, insert: true},
    "member" => %{bypass_rls: false, select: true, insert: true}
  }

  # The fallback bodies, swapped in for the simple ones of the fixture
  @user_id_fallback """
  select
    coalesce(
      nullif(current_setting('app.user_id', true), ''),
      (nullif(current_setting('app.claims', true), '')::jsonb ->> 'sub')
    )::uuid
  """

  @user_role_fallback """
  select
    coalesce(
      nullif(current_setting('app.user_role', true), ''),
      (nullif(current_setting('app.claims', true), '')::jsonb ->> 'role')
    )::text
  """

  @allow :allow
  @deny :deny

  @invalid_uuid {:fallback,
                 {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type uuid"}}}
  @invalid_bool {:fallback,
                 {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type boolean"}}}
  @invalid_json {:fallback,
                 {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type json"}}}
  @regex_non_ascii {:fallback, {:unsupported, :regex_non_ascii}}

  # The qual of typical_slow_read and the check of typical_slow_write, a subselect the parser leaves as raw text
  @slow_unsupported {:fallback, {:unsupported, {:unparsed, :select}}}

  setup_all do
    catalogs =
      Map.new(@versions, fn version ->
        {catalog, _} = Code.eval_file(Path.expand("../fixtures/#{version}/catalog.exs", __DIR__))
        {version, catalog}
      end)

    %{catalogs: catalogs}
  end

  ## Helpers

  # The settings of the example (see PolicyEval.Test.ExampleScenarios), for a user with this role and user id. A nil
  # user id is a user without one: set_config(..., NULL) for the setting, no sub in the claims.
  defp env(opts) do
    role = Keyword.get(opts, :role, "member")
    user_id = Keyword.get(opts, :user_id)
    team = Keyword.fetch!(opts, :team)
    kind = Keyword.get(opts, :kind, "note")

    claims =
      Keyword.get_lazy(opts, :claims, fn ->
        JSON.encode!(if user_id, do: %{"role" => role, "sub" => user_id}, else: %{"role" => role})
      end)

    Env.new(
      %{
        "role" => role,
        "app.team" => team,
        "app.claims" => claims,
        "app.user_id" => user_id,
        "app.user_role" => role,
        "app.headers" => "{}"
      },
      %{"team" => {:text, team}, "kind" => {:text, kind}}
    )
  end

  defp functions(catalog, :simple), do: catalog.functions

  defp functions(catalog, :fallback) do
    Enum.map(catalog.functions, fn
      %{schema: "app", name: "user_id"} = function -> %{function | source: @user_id_fallback}
      %{schema: "app", name: "user_role"} = function -> %{function | source: @user_role_fallback}
      function -> function
    end)
  end

  defp snapshot(policies, functions, overrides \\ %{}) do
    Snapshot.new(
      Map.merge(
        %{rls_enabled: true, rls_forced: false, roles: @roles, policies: policies, functions: functions},
        overrides
      ),
      @profile
    )
  end

  defp named(catalog, names), do: Enum.filter(catalog.policies, &(&1.name in names))

  defp personal_team_policies(catalog) do
    Enum.filter(catalog.policies, &(String.starts_with?(&1.name, "members ") or &1.name == "lobby"))
  end

  defp policy(name, attrs) do
    Map.merge(
      %{name: name, cmd: "r", permissive: true, roles: ["member"], qual: "true", with_check: nil},
      Map.new(attrs)
    )
  end

  defp decide_with(policies, functions, operation, team) do
    PolicyEval.decide(snapshot(policies, functions), env(team: team, user_id: @uid), operation)
  end

  defp policy_attrs(policy), do: Map.take(policy, [:name, :cmd, :permissive, :roles, :qual, :with_check])

  # Runs `decide` for both Postgres versions of the fixtures and both bodies of app.user_id()/app.user_role().
  # `expected` is for the simple bodies of the fixture, `fallback` for the fallback bodies, which differ in one case.
  defp assert_all_variants(catalogs, policies_fun, env, operation, expected, fallback \\ nil) do
    for version <- @versions, variant <- [:simple, :fallback] do
      catalog = catalogs[version]
      snapshot = snapshot(policies_fun.(catalog), functions(catalog, variant))
      want = if variant == :fallback and fallback != nil, do: fallback, else: expected

      assert PolicyEval.decide(snapshot, env, operation) == want, "#{version} with #{variant} functions"
    end
  end

  ## Personal teams
  #
  # Five policies, all TO member:
  #
  #   lobby                                         SELECT  app.team() ~* 'public:lobby'
  #   members read in their own team                SELECT  app.team() = 'user:' || app.user_id()
  #                                                         AND kind IN ('note', 'task')
  #   members read in their own team (initplan)     the same with (select app.user_id())
  #   members write in their own team               INSERT  WITH CHECK, the same expression
  #   members write in their own team (initplan)    the same with (select app.user_id())
  #
  # With the settings that the example sets, app.user_id() is the user id as a uuid: NULL for a
  # missing or empty user id, an error for something that isn't a uuid. Postgres compares text by bytes, and uuid
  # prints as lowercase 8-4-4-4-12.

  describe "personal teams, read" do
    @reads [
      # Teams, for a user whose id is @uid
      %{name: "own user id", team: "user:#{@uid}", user_id: @uid, expect: @allow},
      %{name: "someone else's user id", team: "user:#{@other_uid}", user_id: @uid, expect: @deny},
      # uuid prints lowercase and texteq compares bytes
      %{name: "own user id in upper case", team: "user:#{String.upcase(@uid)}", user_id: @uid, expect: @deny},
      %{name: "the lobby team", team: "public:lobby", user_id: @uid, expect: @allow},
      # ~* ignores case
      %{name: "the lobby team in upper case", team: "PUBLIC:LOBBY", user_id: @uid, expect: @allow},
      # ~ is an unanchored substring match
      %{name: "the lobby team inside another one", team: "xpublic:lobbyy", user_id: @uid, expect: @allow},
      %{name: "a team that matches nothing", team: "room:1", user_id: @uid, expect: @deny},
      # How ~* folds non-ASCII letters depends on the database's collation, so it falls back, even for
      # a team that can't match
      %{name: "a non-ASCII team", team: "public:lobby:é", user_id: @uid, expect: @regex_non_ascii},
      %{name: "a non-ASCII team that can't match", team: "café", user_id: @uid, expect: @regex_non_ascii},
      # The team setting is '', which app.team() turns into NULL: every comparison is NULL, and NULL denies
      %{name: "an empty team", team: "", user_id: @uid, expect: @deny},

      # User ids, for the team "user:" and the canonical uuid
      %{name: "user id in upper case", team: "user:#{@uid}", user_id: String.upcase(@uid), expect: @allow},
      %{name: "braced user id", team: "user:#{@uid}", user_id: "{#{@uid}}", expect: @allow},
      %{name: "unhyphenated user id", team: "user:#{@uid}", user_id: String.replace(@uid, "-", ""), expect: @allow},
      %{
        name: "user id with hyphens after every group",
        team: "user:#{@uid}",
        user_id: "a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11",
        expect: @allow
      },
      # uuid_in doesn't skip whitespace
      %{name: "user id with a leading space", team: "user:#{@uid}", user_id: " #{@uid}", expect: @invalid_uuid},
      # The simple app.user_id() is nullif(user_id, '')::uuid, so NULL, and NULL = ... is NULL, which denies.
      # The fallback one is coalesce(nullif(user_id, ''), claims ->> 'sub')::uuid, and the claims have "sub": "",
      # which is not NULL: ''::uuid raises. (A third-party JWT can have an empty sub.)
      %{name: "empty user id", team: "user:#{@uid}", user_id: "", expect: @deny, fallback: @invalid_uuid},
      # No user id anywhere: NULL with both bodies
      %{name: "no user id", team: "user:#{@uid}", user_id: nil, expect: @deny},
      %{name: "no user id on the lobby team", team: "public:lobby", user_id: nil, expect: @allow},
      # A user id that isn't a uuid, as a third-party auth provider sends: the cast raises where it is
      # reached, and there is nothing to decide the OR without it
      %{name: "user id that isn't a uuid", team: "user:user_2abc", user_id: "user_2abc", expect: @invalid_uuid},
      %{
        name: "user id that isn't a uuid, on a team nothing matches",
        team: "room:1",
        user_id: "user_2abc",
        expect: @invalid_uuid
      },
      # ... and lobby is true, but that doesn't decide the OR: Postgres may have evaluated the failing
      # branch first, and raises, as measured
      %{
        name: "user id that isn't a uuid, on the lobby team",
        team: "public:lobby",
        user_id: "user_2abc",
        expect: @invalid_uuid
      },

      # Roles. No policy is for guest, so there is no permissive policy and Postgres uses `false`
      %{name: "guest, own user id", team: "user:#{@uid}", user_id: @uid, role: "guest", expect: @deny},
      %{name: "guest, the lobby team", team: "public:lobby", user_id: @uid, role: "guest", expect: @deny},
      # Not a role we model, it bypasses RLS
      %{
        name: "admin",
        team: "user:#{@uid}",
        user_id: @uid,
        role: "admin",
        expect: {:fallback, {:role, "admin"}}
      }
    ]

    for %{name: name} = case_ <- @reads, kind <- ["note", "task"] do
      test "#{kind}: #{name}", %{catalogs: catalogs} do
        case_ = unquote(Macro.escape(case_))
        kind = unquote(kind)

        env =
          env(team: case_.team, user_id: case_.user_id, role: Map.get(case_, :role, "member"), kind: kind)

        assert_all_variants(
          catalogs,
          &personal_team_policies/1,
          env,
          :read,
          case_.expect,
          Map.get(case_, :fallback)
        )
      end
    end

    # The policy is only true for two kinds
    test "a kind outside the list, own user id", %{catalogs: catalogs} do
      env = env(team: "user:#{@uid}", user_id: @uid, kind: "comment")
      assert_all_variants(catalogs, &personal_team_policies/1, env, :read, @deny)
    end

    # false AND <error> is false for the executor only if it evaluates the kind comparison first,
    # which the planner decides. Postgres 17 raises here on reads, so it is a fallback
    test "a kind outside the list, user id that isn't a uuid: the failing cast decides", %{catalogs: catalogs} do
      env = env(team: "user:user_2abc", user_id: "user_2abc", kind: "comment")
      assert_all_variants(catalogs, &personal_team_policies/1, env, :read, @invalid_uuid)
    end
  end

  describe "personal teams, write" do
    @writes [
      %{name: "own user id", team: "user:#{@uid}", user_id: @uid, expect: @allow},
      %{name: "someone else's user id", team: "user:#{@other_uid}", user_id: @uid, expect: @deny},
      %{name: "own user id in upper case", team: "user:#{String.upcase(@uid)}", user_id: @uid, expect: @deny},
      # Only the receive side has a policy for the lobby
      %{name: "the lobby team", team: "public:lobby", user_id: @uid, expect: @deny},
      %{name: "the lobby team in upper case", team: "PUBLIC:LOBBY", user_id: @uid, expect: @deny},
      %{name: "the lobby team inside another one", team: "xpublic:lobbyy", user_id: @uid, expect: @deny},
      # The send policies have no regex, but the lobby SELECT policy does, and a write might evaluate
      # it: a fallback, as for a read
      %{name: "a non-ASCII team", team: "public:lobby:é", user_id: @uid, expect: @regex_non_ascii},
      %{name: "an empty team", team: "", user_id: @uid, expect: @deny},
      %{name: "user id in upper case", team: "user:#{@uid}", user_id: String.upcase(@uid), expect: @allow},
      %{name: "braced user id", team: "user:#{@uid}", user_id: "{#{@uid}}", expect: @allow},
      %{name: "unhyphenated user id", team: "user:#{@uid}", user_id: String.replace(@uid, "-", ""), expect: @allow},
      # See the read case
      %{name: "empty user id", team: "user:#{@uid}", user_id: "", expect: @deny, fallback: @invalid_uuid},
      %{name: "no user id", team: "user:#{@uid}", user_id: nil, expect: @deny},
      %{name: "user id that isn't a uuid", team: "user:user_2abc", user_id: "user_2abc", expect: @invalid_uuid},
      # No policy is false, and both send policies fail: nothing to decide with
      %{
        name: "user id that isn't a uuid, on the lobby team",
        team: "public:lobby",
        user_id: "user_2abc",
        expect: @invalid_uuid
      },
      %{name: "guest, own user id", team: "user:#{@uid}", user_id: @uid, role: "guest", expect: @deny},
      %{
        name: "admin",
        team: "user:#{@uid}",
        user_id: @uid,
        role: "admin",
        expect: {:fallback, {:role, "admin"}}
      },
      # The kind is in the list for both, but not for others
      %{name: "own user id, task", team: "user:#{@uid}", user_id: @uid, kind: "task", expect: @allow},
      %{
        name: "own user id, a kind outside the list",
        team: "user:#{@uid}",
        user_id: @uid,
        kind: "file",
        expect: @deny
      },
      # The kind comparison is false, but the failing cast may be evaluated first
      %{
        name: "user id that isn't a uuid, a kind outside the list",
        team: "user:user_2abc",
        user_id: "user_2abc",
        kind: "file",
        expect: @invalid_uuid
      }
    ]

    for %{name: name} = case_ <- @writes do
      test "#{name}", %{catalogs: catalogs} do
        case_ = unquote(Macro.escape(case_))

        env =
          env(
            team: case_.team,
            user_id: case_.user_id,
            role: Map.get(case_, :role, "member"),
            kind: Map.get(case_, :kind, "note")
          )

        assert_all_variants(
          catalogs,
          &personal_team_policies/1,
          env,
          :write,
          case_.expect,
          Map.get(case_, :fallback)
        )
      end
    end
  end

  describe "the same results with the fallback app.user_id()" do
    # assert_all_variants runs every case above with both bodies. This one pins what differs.
    test "differs only for a user id that is an empty string, where the fallback body raises", %{catalogs: catalogs} do
      for operation <- [:read, :write], version <- @versions do
        catalog = catalogs[version]
        env = env(team: "user:#{@uid}", user_id: "")

        simple = snapshot(personal_team_policies(catalog), functions(catalog, :simple))
        fallback = snapshot(personal_team_policies(catalog), functions(catalog, :fallback))

        assert PolicyEval.decide(simple, env, operation) == @deny
        assert PolicyEval.decide(fallback, env, operation) == @invalid_uuid
      end
    end

    # The fallback body parses the claims even when the user id setting is set, as COALESCE can't skip an
    # argument that raises. The simple body doesn't read the claims at all.
    test "falls back for claims that don't parse, even with the user id set", %{catalogs: catalogs} do
      catalog = catalogs["pg17"]
      env = env(team: "user:#{@uid}", user_id: @uid, claims: ~s({"sub":"#{@uid}","x":"\\u0000"}))

      simple = snapshot(personal_team_policies(catalog), functions(catalog, :simple))
      fallback = snapshot(personal_team_policies(catalog), functions(catalog, :fallback))

      assert PolicyEval.decide(simple, env, :read) == @allow

      assert PolicyEval.decide(fallback, env, :read) ==
               {:fallback, {:unsupported, {:raises, :untranslatable_character, "unsupported Unicode escape sequence"}}}
    end
  end

  ## Fallbacks before evaluating

  describe "fallbacks before evaluating" do
    setup %{catalogs: catalogs} do
      catalog = catalogs["pg17"]
      %{catalog: catalog, policies: personal_team_policies(catalog)}
    end

    test "the baseline decides", %{catalog: catalog, policies: policies} do
      snapshot = snapshot(policies, catalog.functions)
      assert PolicyEval.decide(snapshot, env(team: "user:#{@uid}", user_id: @uid), :read) == @allow
    end

    # The reason names a role only if it is a platform one, the others are the policy author's to name.
    for {role, named} <- [
          {"admin", "admin"},
          {"postgres", "postgres"},
          {"editor", :other},
          {"team_member", :other},
          {"", :other},
          {"GUEST", :other}
        ] do
      test "the role #{inspect(role)} is not modelled", %{catalog: catalog, policies: policies} do
        snapshot = snapshot(policies, catalog.functions)
        env = env(team: "user:#{@uid}", user_id: @uid, role: unquote(role))

        assert PolicyEval.decide(snapshot, env, :read) == {:fallback, {:role, unquote(named)}}
        assert PolicyEval.decide(snapshot, env, :write) == {:fallback, {:role, unquote(named)}}
      end
    end

    test "a missing role setting", %{catalog: catalog, policies: policies} do
      snapshot = snapshot(policies, catalog.functions)
      env = Env.new(%{}, %{})

      assert PolicyEval.decide(snapshot, env, :read) == {:fallback, {:role, nil}}
    end

    test "RLS disabled", %{catalog: catalog, policies: policies} do
      snapshot = snapshot(policies, catalog.functions, %{rls_enabled: false})
      assert PolicyEval.decide(snapshot, env(team: "t", user_id: @uid), :read) == {:fallback, :rls_disabled}
    end

    test "RLS forced", %{catalog: catalog, policies: policies} do
      snapshot = snapshot(policies, catalog.functions, %{rls_forced: true})
      assert PolicyEval.decide(snapshot, env(team: "t", user_id: @uid), :write) == {:fallback, :rls_forced}
    end

    test "a role that bypasses RLS", %{catalog: catalog, policies: policies} do
      roles = %{@roles | "member" => %{bypass_rls: true, select: true, insert: true}}
      snapshot = snapshot(policies, catalog.functions, %{roles: roles})

      assert PolicyEval.decide(snapshot, env(team: "t", user_id: @uid), :read) == {:fallback, {:bypass_rls, "member"}}
      # another role isn't affected
      assert PolicyEval.decide(snapshot, env(team: "t", user_id: @uid, role: "guest"), :read) == @deny
    end

    test "a role missing from the snapshot", %{catalog: catalog, policies: policies} do
      snapshot = snapshot(policies, catalog.functions, %{roles: Map.delete(@roles, "guest")})

      assert PolicyEval.decide(snapshot, env(team: "t", role: "guest"), :read) ==
               {:fallback, {:role_not_in_snapshot, "guest"}}
    end

    test "a missing grant is a fallback for the operation it is needed for", %{catalog: catalog, policies: policies} do
      no_select = %{@roles | "member" => %{bypass_rls: false, select: false, insert: true}}
      no_insert = %{@roles | "member" => %{bypass_rls: false, select: true, insert: false}}
      env = env(team: "user:#{@uid}", user_id: @uid)

      # A write needs select too: the profile sets write_plans_select, see the PolicySet moduledoc
      snapshot = snapshot(policies, catalog.functions, %{roles: no_select})
      assert PolicyEval.decide(snapshot, env, :read) == {:fallback, {:missing_grant, "member", :select}}
      assert PolicyEval.decide(snapshot, env, :write) == {:fallback, {:missing_grant, "member", :select}}

      snapshot = snapshot(policies, catalog.functions, %{roles: no_insert})
      assert PolicyEval.decide(snapshot, env, :read) == @allow
      assert PolicyEval.decide(snapshot, env, :write) == {:fallback, {:missing_grant, "member", :insert}}

      # With neither, the one the write itself needs is reported
      none = %{@roles | "member" => %{bypass_rls: false, select: false, insert: false}}
      snapshot = snapshot(policies, catalog.functions, %{roles: none})
      assert PolicyEval.decide(snapshot, env, :write) == {:fallback, {:missing_grant, "member", :insert}}
    end

    test "a policy for a role that isn't modelled, for the command being decided", %{
      catalog: catalog,
      policies: policies
    } do
      extra = fn cmd -> policy("for_team", cmd: cmd, roles: ["team_member"], qual: "true", with_check: "true") end
      env = env(team: "user:#{@uid}", user_id: @uid)

      for {cmd, read, write} <- [
            {"r", {:fallback, :unmodelled_policy_role}, @allow},
            {"a", @allow, {:fallback, :unmodelled_policy_role}},
            {"*", {:fallback, :unmodelled_policy_role}, {:fallback, :unmodelled_policy_role}},
            # not decided here at all
            {"w", @allow, @allow},
            {"d", @allow, @allow}
          ] do
        snapshot = snapshot(policies ++ [extra.(cmd)], catalog.functions)
        assert PolicyEval.decide(snapshot, env, :read) == read, "cmd #{cmd}"
        assert PolicyEval.decide(snapshot, env, :write) == write, "cmd #{cmd}"
      end
    end

    test "a policy naming several roles falls back if any is not modelled", %{catalog: catalog, policies: policies} do
      snapshot =
        snapshot(policies ++ [policy("p", roles: ["member", "team_member"])], catalog.functions)

      assert PolicyEval.decide(snapshot, env(team: "t", user_id: @uid), :read) == {:fallback, :unmodelled_policy_role}
    end

    test "policies for public, guest, member and admin are fine", %{catalog: catalog, policies: policies} do
      extra =
        for role <- ["public", "guest", "member", "admin"],
            do: policy("for_#{role}", roles: [role], qual: "false")

      snapshot = snapshot(policies ++ extra, catalog.functions)

      assert PolicyEval.decide(snapshot, env(team: "user:#{@uid}", user_id: @uid), :read) == @allow
    end

    test "an applicable policy without the expression to evaluate", %{catalog: catalog, policies: policies} do
      read = policy("no_using", cmd: "r", qual: nil)
      write = policy("no_check", cmd: "a", qual: nil, with_check: nil)
      all = policy("no_expression", cmd: "*", qual: nil, with_check: nil)
      env = env(team: "user:#{@uid}", user_id: @uid)

      assert PolicyEval.decide(snapshot(policies ++ [read], catalog.functions), env, :read) ==
               {:fallback, :policy_without_expression}

      assert PolicyEval.decide(snapshot(policies ++ [write], catalog.functions), env, :write) ==
               {:fallback, :policy_without_expression}

      assert PolicyEval.decide(snapshot(policies ++ [all], catalog.functions), env, :read) ==
               {:fallback, :policy_without_expression}

      # A write also needs the USING of the SELECT and ALL policies, see the PolicySet moduledoc
      assert PolicyEval.decide(snapshot(policies ++ [all], catalog.functions), env, :write) ==
               {:fallback, :select_policy_unsupported}

      assert PolicyEval.decide(snapshot(policies ++ [read], catalog.functions), env, :write) ==
               {:fallback, :select_policy_unsupported}

      # a policy that doesn't apply doesn't matter
      assert PolicyEval.decide(snapshot(policies ++ [write], catalog.functions), env, :read) == @allow

      assert PolicyEval.decide(
               snapshot(policies ++ [policy("guest_only", roles: ["guest"], qual: nil)], catalog.functions),
               env,
               :read
             ) == @allow
    end

    test "anything that raises is a fallback", %{catalog: catalog} do
      broken = %Policy{
        name: "broken",
        cmd: "r",
        permissive: true,
        roles: ["member"],
        using: {{:apply, PolicyEval.Value, :no_such_primitive, []}, :bool},
        with_check: nil
      }

      snapshot = %Snapshot{snapshot([], catalog.functions) | policies: [broken]}

      # the module, not the message, which names the function and may hold input
      assert PolicyEval.decide(snapshot, env(team: "t"), :read) == {:fallback, {:exception, UndefinedFunctionError}}

      assert {:fallback, {:exception, module}} =
               PolicyEval.decide(%Snapshot{snapshot | policies: :oops}, env(team: "t"), :read)

      assert is_atom(module)

      assert {:fallback, {:exception, _}} = PolicyEval.decide(snapshot([], []), :not_an_env, :read)
    end

    test "a table fact that isn't the expected boolean is the unsafe answer", %{catalog: catalog, policies: policies} do
      env = env(team: "user:#{@uid}", user_id: @uid)
      snapshot = snapshot(policies, catalog.functions)

      assert PolicyEval.decide(%Snapshot{snapshot | rls_enabled: nil}, env, :read) == {:fallback, :rls_disabled}
      assert PolicyEval.decide(%Snapshot{snapshot | rls_forced: nil}, env, :read) == {:fallback, :rls_forced}

      roles = %{"member" => %{select: true, insert: true}}

      assert PolicyEval.decide(%Snapshot{snapshot | roles: roles}, env, :read) ==
               {:fallback, {:bypass_rls, "member"}}

      roles = %{"member" => %{bypass_rls: false}}

      assert PolicyEval.decide(%Snapshot{snapshot | roles: roles}, env, :read) ==
               {:fallback, {:missing_grant, "member", :select}}

      assert PolicyEval.decide(%Snapshot{profile: @profile}, env, :read) == {:fallback, :rls_disabled}
      # a snapshot without a profile can't be decided
      assert {:fallback, {:exception, _module}} = PolicyEval.decide(%Snapshot{}, env, :read)
    end
  end

  describe "a setting the env lacks" do
    # Evaluation keeps the name of the setting, and decide/3 keeps it only for a platform setting of
    # the profile. The others are the policy author's to name.
    for {setting, named} <- [
          {"app.expires_at", "app.expires_at"},
          {"app.other", "app.other"},
          {"App.expires_at", :other},
          {"custom.secret", :other}
        ] do
      test "#{setting} in a read, in a write and in a SELECT policy of a write" do
        check = "(current_setting('#{unquote(setting)}'::text, true) = 'x'::text)"
        want = {:fallback, {:unsupported, {:unknown_setting, unquote(named)}}}
        env = env(team: "t", user_id: @uid)

        assert PolicyEval.decide(snapshot([policy("p", qual: check)], []), env, :read) == want

        assert PolicyEval.decide(snapshot([policy("p", cmd: "a", qual: nil, with_check: check)], []), env, :write) ==
                 want

        select_and_insert = [policy("s", qual: check), policy("i", cmd: "a", qual: nil, with_check: "true")]
        assert PolicyEval.decide(snapshot(select_and_insert, []), env, :write) == want
      end
    end
  end

  ## Combining policies

  describe "combining" do
    @team_is_x "(app.team() = 'x'::text)"
    @team_is_y "(app.team() = 'y'::text)"

    setup %{catalogs: catalogs} do
      %{functions: catalogs["pg17"].functions}
    end

    test "permissive policies are OR'd", %{functions: functions} do
      policies = [policy("a", qual: @team_is_x), policy("b", qual: @team_is_y)]

      assert decide_with(policies, functions, :read, "x") == @allow
      assert decide_with(policies, functions, :read, "y") == @allow
      assert decide_with(policies, functions, :read, "z") == @deny
    end

    test "restrictive policies are AND'd with the permissive ones", %{functions: functions} do
      policies = [
        policy("a", qual: "true"),
        policy("r1", permissive: false, qual: "(app.team() <> 'x'::text)"),
        policy("r2", permissive: false, qual: "(app.team() <> 'y'::text)")
      ]

      assert decide_with(policies, functions, :read, "z") == @allow
      assert decide_with(policies, functions, :read, "x") == @deny
      assert decide_with(policies, functions, :read, "y") == @deny
    end

    test "restrictive policies alone deny, and are never evaluated", %{functions: functions} do
      policies = [policy("r", permissive: false, qual: "true")]
      assert decide_with(policies, functions, :read, "x") == @deny

      # not even a restrictive policy we couldn't evaluate
      policies = [policy("r", permissive: false, qual: "(app.email() = 'a'::text)")]
      assert decide_with(policies, functions, :read, "x") == @deny
    end

    test "no policy at all denies", %{functions: functions} do
      assert decide_with([], functions, :read, "x") == @deny
      assert decide_with([], functions, :write, "x") == @deny
    end

    test "NULL denies, for permissive and restrictive policies", %{functions: functions} do
      assert decide_with([policy("a", qual: "(app.team() = NULL::text)")], functions, :read, "x") == @deny

      policies = [policy("a", qual: "true"), policy("r", permissive: false, qual: "(app.team() = NULL::text)")]
      assert decide_with(policies, functions, :read, "x") == @deny
    end

    test "a NULL permissive policy next to a true one allows", %{functions: functions} do
      policies = [policy("a", qual: "(app.team() = NULL::text)"), policy("b", qual: "true")]
      assert decide_with(policies, functions, :read, "x") == @allow
    end

    @unsupported_email {:fallback, {:unsupported, {:function, "app.email", :not_in_snapshot}}}

    test "an unsupported policy makes the decision a fallback, whatever the others say", %{functions: functions} do
      policies = [policy("a", qual: "(app.email() = 'a'::text)"), policy("b", qual: @team_is_x)]

      assert decide_with(policies, functions, :read, "x") == @unsupported_email
      assert decide_with(policies, functions, :read, "y") == @unsupported_email

      # a restrictive policy that fails doesn't decide it either
      policies = [policy("a", qual: "(app.email() = 'a'::text)"), policy("r", permissive: false, qual: @team_is_y)]
      assert decide_with(policies, functions, :read, "x") == @unsupported_email
    end

    test "an expression that isn't boolean is unsupported", %{functions: functions} do
      policies = [policy("a", qual: "app.team()")]

      assert decide_with(policies, functions, :read, "x") == {:fallback, {:unsupported, {:not_boolean, :text}}}
    end

    test "reads use USING and ignore WITH CHECK", %{functions: functions} do
      policies = [policy("a", cmd: "*", qual: @team_is_x, with_check: @team_is_y)]

      assert decide_with(policies, functions, :read, "x") == @allow
      assert decide_with(policies, functions, :read, "y") == @deny
    end

    test "writes use WITH CHECK, and USING for ALL policies that have none", %{functions: functions} do
      both = [policy("a", cmd: "*", qual: @team_is_x, with_check: @team_is_y)]
      assert decide_with(both, functions, :write, "y") == @allow
      assert decide_with(both, functions, :write, "x") == @deny

      using_only = [policy("a", cmd: "*", qual: @team_is_x, with_check: nil)]
      assert decide_with(using_only, functions, :write, "x") == @allow
      assert decide_with(using_only, functions, :write, "y") == @deny

      insert = [policy("a", cmd: "a", qual: nil, with_check: @team_is_x)]
      assert decide_with(insert, functions, :write, "x") == @allow
      assert decide_with(insert, functions, :write, "y") == @deny
    end

    test "a read ignores INSERT policies and a write ignores SELECT policies", %{functions: functions} do
      policies = [policy("r", cmd: "r", qual: "true"), policy("a", cmd: "a", qual: nil, with_check: "false")]

      assert decide_with(policies, functions, :read, "x") == @allow
      assert decide_with(policies, functions, :write, "x") == @deny
    end

    test "UPDATE and DELETE policies are never used", %{functions: functions} do
      policies = [policy("u", cmd: "w", qual: "true", with_check: "true"), policy("d", cmd: "d", qual: "true")]

      assert decide_with(policies, functions, :read, "x") == @deny
      assert decide_with(policies, functions, :write, "x") == @deny
    end

    test "a policy applies to the roles it names, or to public", %{functions: functions} do
      policies = [policy("for_guest", roles: ["guest"], qual: "true")]
      env = fn role -> env(team: "x", user_id: @uid, role: role) end

      assert PolicyEval.decide(snapshot(policies, functions), env.("guest"), :read) == @allow
      assert PolicyEval.decide(snapshot(policies, functions), env.("member"), :read) == @deny

      policies = [policy("for_public", roles: ["public"], qual: "true")]
      assert PolicyEval.decide(snapshot(policies, functions), env.("guest"), :read) == @allow
      assert PolicyEval.decide(snapshot(policies, functions), env.("member"), :read) == @allow

      policies = [policy("both", roles: ["guest", "member"], qual: "true")]
      assert PolicyEval.decide(snapshot(policies, functions), env.("guest"), :read) == @allow
      assert PolicyEval.decide(snapshot(policies, functions), env.("member"), :read) == @allow
    end

    test "the order of the policies doesn't matter", %{functions: functions} do
      policies = [
        policy("a", qual: "(app.email() = 'a'::text)"),
        policy("b", qual: @team_is_x),
        policy("r", permissive: false, qual: "true")
      ]

      for ordered <- [policies, Enum.reverse(policies)] do
        assert decide_with(ordered, functions, :read, "x") == @unsupported_email
      end
    end
  end

  ## Writes that plan a SELECT (write_plans_select)

  describe "a write also needs the SELECT policies to be modelled" do
    @team_x "(app.team() = 'x'::text)"
    @unsupported_select "(app.email() = 'a'::text)"

    setup %{catalogs: catalogs} do
      %{functions: catalogs["pg17"].functions}
    end

    defp insert_policy, do: policy("insert", cmd: "a", qual: nil, with_check: @team_x)

    defp write_with(policies, functions, opts \\ []) do
      role = Keyword.get(opts, :role, "member")
      user_id = Keyword.get(opts, :user_id, @uid)
      PolicyEval.decide(snapshot(policies, functions), env(team: "x", user_id: user_id, role: role), :write)
    end

    test "a SELECT policy that is supported doesn't matter", %{functions: functions} do
      assert write_with([insert_policy(), policy("select", qual: @team_x)], functions) == @allow
      assert write_with([insert_policy(), policy("select", qual: "false")], functions) == @allow
    end

    test "a SELECT policy with an unsupported expression is a fallback", %{functions: functions} do
      policies = [insert_policy(), policy("select_email", qual: @unsupported_select)]

      assert write_with(policies, functions) == {:fallback, :select_policy_unsupported}
      # even though the INSERT policy decides on its own
      assert write_with([insert_policy()], functions) == @allow
    end

    test "unsupported anywhere in the expression counts", %{functions: functions} do
      for qual <- [
            "(#{@team_x} AND (app.email() = 'a'::text))",
            "(#{@team_x} OR (NOT (app.email() = 'a'::text)))",
            "(app.team() = ANY (ARRAY['a'::text, app.email()]))",
            "COALESCE((app.email() = 'a'::text), true)",
            "( SELECT true\n   FROM pg_sleep((1)::double precision) pg_sleep(pg_sleep))",
            "(private = true)"
          ] do
        policies = [insert_policy(), policy("select", qual: qual)]
        assert write_with(policies, functions) == {:fallback, :select_policy_unsupported}, qual
      end
    end

    test "a SELECT policy without a USING expression is a fallback", %{functions: functions} do
      policies = [insert_policy(), policy("select", qual: nil)]
      assert write_with(policies, functions) == {:fallback, :select_policy_unsupported}
    end

    test "an ALL policy counts for its USING, even if the write uses its WITH CHECK", %{functions: functions} do
      policies = [policy("all", cmd: "*", qual: @unsupported_select, with_check: @team_x)]
      assert write_with(policies, functions) == {:fallback, :select_policy_unsupported}

      policies = [policy("all", cmd: "*", qual: nil, with_check: @team_x)]
      assert write_with(policies, functions) == {:fallback, :select_policy_unsupported}

      policies = [policy("all", cmd: "*", qual: @team_x, with_check: @team_x)]
      assert write_with(policies, functions) == @allow
    end

    test "restrictive SELECT policies count too, even when they would not be evaluated", %{functions: functions} do
      policies = [insert_policy(), policy("restrictive", permissive: false, qual: @unsupported_select)]
      assert write_with(policies, functions) == {:fallback, :select_policy_unsupported}
    end

    test "only the policies that might apply to the role count", %{functions: functions} do
      policies = [
        policy("insert", cmd: "a", roles: ["guest", "member"], qual: nil, with_check: @team_x),
        policy("for_guest", roles: ["guest"], qual: @unsupported_select)
      ]

      assert write_with(policies, functions) == @allow

      assert write_with(policies, functions, role: "guest") == {:fallback, :select_policy_unsupported}

      # public applies to everyone
      policies = [insert_policy(), policy("for_public", roles: ["public"], qual: @unsupported_select)]
      assert write_with(policies, functions) == {:fallback, :select_policy_unsupported}
    end

    test "a policy for a role that isn't modelled might apply, by membership", %{functions: functions} do
      policies = [insert_policy(), policy("for_team", roles: ["team_member"], qual: @unsupported_select)]
      assert write_with(policies, functions) == {:fallback, :select_policy_unsupported}

      # one we can read can't fail the statement by being there
      policies = [insert_policy(), policy("for_team", roles: ["team_member"], qual: @team_x)]
      assert write_with(policies, functions) == @allow
    end

    test "UPDATE and DELETE policies don't count", %{functions: functions} do
      policies = [
        insert_policy(),
        policy("update", cmd: "w", qual: @unsupported_select, with_check: @unsupported_select),
        policy("delete", cmd: "d", qual: nil)
      ]

      assert write_with(policies, functions) == @allow
    end

    test "a SELECT policy that raises for this input is a fallback", %{functions: functions} do
      # Against Postgres 17 a write-only call that plans the SELECT didn't raise for a policy like
      # this, with no probe row to evaluate it for. Against a Multigres cluster it did.
      raising = "((app.team() = 'x'::text) AND ((( SELECT app.user_id() AS user_id))::text = 'x'::text))"
      policies = [insert_policy(), policy("select", qual: raising)]

      assert write_with(policies, functions, user_id: "user_2abc") ==
               {:fallback,
                {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type uuid"}}}

      assert write_with(policies, functions) == @allow
    end

    test "a read is not affected, it evaluates the policies it needs", %{functions: functions} do
      policies = [insert_policy(), policy("select", qual: @team_x)]
      assert PolicyEval.decide(snapshot(policies, functions), env(team: "x", user_id: @uid), :read) == @allow

      # the INSERT policy is not even looked at
      policies = [
        policy("insert", cmd: "a", qual: nil, with_check: @unsupported_select),
        policy("select", qual: @team_x)
      ]

      assert PolicyEval.decide(snapshot(policies, functions), env(team: "x", user_id: @uid), :read) == @allow
    end

    test "the grants are checked first", %{functions: functions} do
      roles = %{@roles | "member" => %{bypass_rls: false, select: false, insert: true}}
      policies = [insert_policy(), policy("select", qual: @unsupported_select)]

      assert PolicyEval.decide(snapshot(policies, functions, %{roles: roles}), env(team: "x", user_id: @uid), :write) ==
               {:fallback, {:missing_grant, "member", :select}}
    end

    test "with no policy for SELECT at all, the write decides", %{functions: functions} do
      assert write_with([insert_policy()], functions) == @allow
      assert write_with([], functions) == @deny
    end

    test "the personal-team SELECT policies are modelled, so their writes decide", %{catalogs: catalogs} do
      for version <- @versions, variant <- [:simple, :fallback] do
        catalog = catalogs[version]
        snapshot = snapshot(personal_team_policies(catalog), functions(catalog, variant))

        assert PolicyEval.decide(snapshot, env(team: "user:#{@uid}", user_id: @uid), :write) == @allow,
               "#{version} #{variant}"
      end
    end
  end

  ## The typical policies of the example (PolicyEval.Test.ExamplePolicies)

  describe "claim-based policies" do
    @claim_cases [
      {"true", ~s({"notes_read":true}), @allow},
      {"the string true", ~s({"notes_read":"true"}), @allow},
      {"the string yes", ~s({"notes_read":"yes"}), @allow},
      {"false", ~s({"notes_read":false}), @deny},
      {"the string 0", ~s({"notes_read":"0"}), @deny},
      # ->> gives NULL, COALESCE turns it into false
      {"JSON null", ~s({"notes_read":null}), @deny},
      {"a missing key", ~s({"other":true}), @deny},
      {"an empty object", "{}", @deny},
      {"an array root", ~s(["notes_read"]), @deny},
      {"a string root", ~s("notes_read"), @deny},
      # jsonb keeps the last of duplicate keys
      {"duplicate keys", ~s({"notes_read":false,"notes_read":true}), @allow},
      # ::boolean raises
      {"a string that isn't a boolean", ~s({"notes_read":"maybe"}), @invalid_bool},
      # A number would be allowed by Postgres ('1' is true) but we don't render numbers
      {"a number", ~s({"notes_read":1}), {:fallback, {:unsupported, :jsonb_number_text}}},
      {"an object", ~s({"notes_read":{"a":1}}), {:fallback, {:unsupported, :jsonb_container_text}}},
      {"a NUL escape", ~s({"notes_read":"\\u0000"}),
       {:fallback, {:unsupported, {:raises, :untranslatable_character, "unsupported Unicode escape sequence"}}}},
      # The policy casts the setting itself, with no nullif: '' isn't JSON
      {"not JSON", "not json", @invalid_json},
      {"empty claims", "", @invalid_json}
    ]

    for {name, claims, expect} <- @claim_cases do
      test "notes_read is #{name}", %{catalogs: catalogs} do
        env = env(team: "fixture_team", kind: "note", claims: unquote(claims))

        assert_all_variants(
          catalogs,
          &named(&1, ["typical_member_read_notes_by_claim"]),
          env,
          :read,
          unquote(Macro.escape(expect))
        )
      end
    end

    test "the claim only matters on the team and kind of the policy", %{catalogs: catalogs} do
      policies = &named(&1, ["typical_member_read_notes_by_claim"])

      # another team, or another kind, is false before the claim is looked at ...
      for {team, kind} <- [{"other_team", "note"}, {"fixture_team", "task"}] do
        env = env(team: team, kind: kind, claims: ~s({"notes_read":true}))
        assert_all_variants(catalogs, policies, env, :read, @deny)

        # ... and one the claim can't change, though the claim here raises. That decides nothing,
        # as Postgres may have evaluated the cast first
        env = env(team: team, kind: kind, claims: ~s({"notes_read":"maybe"}))
        assert_all_variants(catalogs, policies, env, :read, @invalid_bool)

        env = env(team: team, kind: kind, claims: "not json")
        assert_all_variants(catalogs, policies, env, :read, @invalid_json)
      end
    end

    test "the task policy reads tasks_read", %{catalogs: catalogs} do
      policies = &named(&1, ["typical_member_read_tasks_by_claim"])
      env = &env(team: "fixture_team", kind: "task", claims: &1)

      assert_all_variants(catalogs, policies, env.(~s({"tasks_read":true})), :read, @allow)
      assert_all_variants(catalogs, policies, env.(~s({"notes_read":true})), :read, @deny)
    end

    test "with the other policies on top, a true one doesn't decide", %{catalogs: catalogs} do
      policies =
        &named(&1, ["typical_member_read_notes_by_claim", "typical_member_read_notes"])

      env = env(team: "fixture_team", kind: "note", claims: ~s({"notes_read":"maybe"}))

      assert_all_variants(catalogs, policies, env, :read, @invalid_bool)
    end
  end

  describe "typical policies" do
    test "team and kind", %{catalogs: catalogs} do
      read = &named(&1, ["typical_member_read_notes"])
      write = &named(&1, ["typical_member_write_notes"])

      for {team, kind, expect} <- [
            {"fixture_team", "note", @allow},
            {"fixture_team", "task", @deny},
            {"other", "note", @deny},
            {"fixture_team ", "note", @deny},
            {"FIXTURE_TOPIC", "note", @deny}
          ] do
        env = env(team: team, kind: kind)
        assert_all_variants(catalogs, read, env, :read, expect)
        assert_all_variants(catalogs, write, env, :write, expect)
      end
    end

    test "kind lists", %{catalogs: catalogs} do
      read = &named(&1, ["typical_member_read_notes_and_tasks"])

      write =
        &named(&1, ["typical_member_write_notes_and_tasks", "typical_member_write_files"])

      for {kind, expect} <- [{"note", @allow}, {"task", @allow}, {"other", @deny}] do
        env = env(team: "fixture_team", kind: kind)
        assert_all_variants(catalogs, read, env, :read, expect)
        assert_all_variants(catalogs, write, env, :write, expect)
      end

      # the other write policy is for file
      env = env(team: "fixture_team", kind: "file")
      assert_all_variants(catalogs, write, env, :write, @allow)
    end

    test "true policies allow everything", %{catalogs: catalogs} do
      env = env(team: "anything", kind: "task")

      assert_all_variants(catalogs, &named(&1, ["typical_member_read_all"]), env, :read, @allow)
      assert_all_variants(catalogs, &named(&1, ["typical_member_insert_all"]), env, :write, @allow)
    end

    test "a policy that matches on the user id", %{catalogs: catalogs} do
      user_id = "c0ffee00-1111-4222-8333-444455556666"
      read = &named(&1, ["typical_member_read_matching_user_id"])
      write = &named(&1, ["typical_member_write_matching_user_id"])

      for {user_id_in_session, expect} <- [
            {user_id, @allow},
            # uuid_out prints lowercase
            {String.upcase(user_id), @allow},
            {"{#{user_id}}", @allow},
            {@uid, @deny},
            {nil, @deny},
            {"user_2abc", @invalid_uuid}
          ] do
        env = env(team: "t", user_id: user_id_in_session)
        assert_all_variants(catalogs, read, env, :read, expect)
        assert_all_variants(catalogs, write, env, :write, expect)
      end
    end

    test "a policy on team, kind and user id", %{catalogs: catalogs} do
      policies = &named(&1, ["typical_member_read_own_tasks"])
      user_id = "c0ffee00-1111-4222-8333-444455556666"

      assert_all_variants(
        catalogs,
        policies,
        env(team: "fixture_team", kind: "task", user_id: user_id),
        :read,
        @allow
      )

      assert_all_variants(
        catalogs,
        policies,
        env(team: "fixture_team", kind: "task", user_id: @uid),
        :read,
        @deny
      )

      assert_all_variants(catalogs, policies, env(team: "other", kind: "task", user_id: user_id), :read, @deny)

      assert_all_variants(
        catalogs,
        policies,
        env(team: "fixture_team", kind: "note", user_id: user_id),
        :read,
        @deny
      )

      # the cast of app.user_id() fails, unless the team or kind is wrong first
      assert_all_variants(
        catalogs,
        policies,
        env(team: "fixture_team", kind: "task", user_id: "x"),
        :read,
        @invalid_uuid
      )

      assert_all_variants(
        catalogs,
        policies,
        env(team: "other", kind: "task", user_id: "x"),
        :read,
        @invalid_uuid
      )
    end

    test "policies on the role, for public", %{catalogs: catalogs} do
      read = &named(&1, ["typical_read_matching_user_role"])
      write = &named(&1, ["typical_write_matching_user_role"])

      # app.user_role() is the role of the token, which is also the role the probe runs as
      for {role, expect} <- [{"member", @allow}, {"guest", @deny}] do
        env = env(team: "t", role: role)
        assert_all_variants(catalogs, read, env, :read, expect)
        assert_all_variants(catalogs, write, env, :write, expect)
      end
    end

    test "a restrictive policy we can't evaluate", %{catalogs: catalogs} do
      policies = &named(&1, ["typical_member_read_all", "typical_slow_read"])

      # true AND unsupported: nothing to decide with
      env = env(team: "t")
      assert_all_variants(catalogs, policies, env, :read, @slow_unsupported)

      policies = &named(&1, ["typical_member_read_notes", "typical_slow_read"])

      # false AND unsupported: nothing to decide with either
      env = env(team: "other")
      assert_all_variants(catalogs, policies, env, :read, @slow_unsupported)

      # no permissive policy applies for write... the slow write is restrictive too
      policies = &named(&1, ["typical_slow_write"])
      assert_all_variants(catalogs, policies, env(team: "t"), :write, @deny)

      policies = &named(&1, ["typical_member_insert_all", "typical_slow_write"])
      assert_all_variants(catalogs, policies, env(team: "t"), :write, @slow_unsupported)
    end

    test "a broken permissive policy decides nothing, whatever the others say", %{catalogs: catalogs} do
      broken = "typical_broken_read"
      unsupported = {:fallback, {:unsupported, {:function, :other_schema, :not_allowlisted}}}

      for policies <- [
            &named(&1, [broken, "typical_member_read_all"]),
            &named(&1, [broken, "typical_member_read_notes"])
          ] do
        assert_all_variants(catalogs, policies, env(team: "t"), :read, unsupported)
      end
    end

    test "ALL policy with only USING", %{catalogs: catalogs} do
      policies = &named(&1, ["grammar_all_using_only"])

      assert_all_variants(catalogs, policies, env(team: "x"), :read, @allow)
      assert_all_variants(catalogs, policies, env(team: "x"), :write, @allow)
      assert_all_variants(catalogs, policies, env(team: "y"), :read, @deny)
      assert_all_variants(catalogs, policies, env(team: "y"), :write, @deny)
    end

    test "restrictive policy of the grammar", %{catalogs: catalogs} do
      policies = &named(&1, ["typical_member_read_all", "grammar_restrictive"])

      assert_all_variants(catalogs, policies, env(team: "x"), :read, @allow)
      assert_all_variants(catalogs, policies, env(team: "y"), :read, @deny)
    end

    test "every policy of the fixtures can be decided or falls back, without raising", %{catalogs: catalogs} do
      for version <- @versions, variant <- [:simple, :fallback], policy <- catalogs[version].policies do
        for role <- ["guest", "member"], operation <- [:read, :write] do
          snapshot = snapshot([policy_attrs(policy)], functions(catalogs[version], variant))
          decision = PolicyEval.decide(snapshot, env(team: "fixture_team", user_id: @uid, role: role), operation)

          refute match?({:fallback, {:exception, _}}, decision), "#{version} #{policy.name}"
        end
      end
    end
  end
end
