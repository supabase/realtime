defmodule SqlLogex.PolicySetTest do
  use ExUnit.Case, async: true

  alias SqlLogex.Env
  alias SqlLogex.Policy
  alias SqlLogex.Snapshot

  @versions ["pg17", "pg15"]

  @uid "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @other_uid "b1ffcd00-8d1c-4ff9-cc7e-7cc0ce491b22"

  @roles %{
    "anon" => %{bypass_rls: false, select: true, insert: true},
    "authenticated" => %{bypass_rls: false, select: true, insert: true}
  }

  # supabase/auth's current bodies (migration 20220224000811), swapped in for the ones of the fixture
  @uid_supabase_auth """
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.sub', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
  )::uuid
  """

  @role_supabase_auth """
  select
  coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
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

  # The qual of generator_slow_read and the check of generator_slow_write, which the parser leaves as raw text
  @slow_subselect "( SELECT true\n   FROM pg_sleep((1)::double precision) pg_sleep(pg_sleep))"
  @slow_unsupported {:fallback, {:unsupported, {:unparsed, @slow_subselect}}}

  setup_all do
    catalogs =
      Map.new(@versions, fn version ->
        {catalog, _} = Code.eval_file(Path.expand("../fixtures/#{version}/catalog.exs", __DIR__))
        {version, catalog}
      end)

    %{catalogs: catalogs}
  end

  ## Helpers

  # The settings Realtime sets (see SqlLogex.Env), for a JWT with this role and sub. A nil sub is
  # a token without one: set_config(..., NULL) for the setting, no key in the claims.
  defp env(opts) do
    role = Keyword.get(opts, :role, "authenticated")
    sub = Keyword.get(opts, :sub)
    topic = Keyword.fetch!(opts, :topic)
    extension = Keyword.get(opts, :extension, "broadcast")

    claims =
      Keyword.get_lazy(opts, :claims, fn ->
        JSON.encode!(if sub, do: %{"role" => role, "sub" => sub}, else: %{"role" => role})
      end)

    Env.new(
      %{
        "role" => role,
        "realtime.topic" => topic,
        "request.jwt.claims" => claims,
        "request.jwt.claim.sub" => sub,
        "request.jwt.claim.role" => role,
        "request.headers" => "{}"
      },
      %{"topic" => {:text, topic}, "extension" => {:text, extension}}
    )
  end

  defp functions(catalog, :legacy), do: catalog.functions

  defp functions(catalog, :supabase_auth) do
    Enum.map(catalog.functions, fn
      %{schema: "auth", name: "uid"} = function -> %{function | source: @uid_supabase_auth}
      %{schema: "auth", name: "role"} = function -> %{function | source: @role_supabase_auth}
      function -> function
    end)
  end

  defp snapshot(policies, functions, overrides \\ %{}) do
    Snapshot.new(
      Map.merge(
        %{rls_enabled: true, rls_forced: false, roles: @roles, policies: policies, functions: functions},
        overrides
      )
    )
  end

  defp named(catalog, names), do: Enum.filter(catalog.policies, &(&1.name in names))

  defp user_channel_policies(catalog) do
    Enum.filter(catalog.policies, &(String.starts_with?(&1.name, "users ") or &1.name == "lobby"))
  end

  defp policy(name, attrs) do
    Map.merge(
      %{name: name, cmd: "r", permissive: true, roles: ["authenticated"], qual: "true", with_check: nil},
      Map.new(attrs)
    )
  end

  defp decide_with(policies, functions, operation, topic) do
    SqlLogex.decide(snapshot(policies, functions), env(topic: topic, sub: @uid), operation)
  end

  defp policy_attrs(policy), do: Map.take(policy, [:name, :cmd, :permissive, :roles, :qual, :with_check])

  # Runs `decide` for both Postgres versions of the fixtures and both bodies of auth.uid()/auth.role().
  # `expected` is for the legacy bodies of the fixture, `supabase_auth` for supabase/auth's, which differ in one case.
  defp assert_all_variants(catalogs, policies_fun, env, operation, expected, supabase_auth \\ nil) do
    for version <- @versions, variant <- [:legacy, :supabase_auth] do
      catalog = catalogs[version]
      snapshot = snapshot(policies_fun.(catalog), functions(catalog, variant))
      want = if variant == :supabase_auth and supabase_auth != nil, do: supabase_auth, else: expected

      assert SqlLogex.decide(snapshot, env, operation) == want, "#{version} with #{variant} functions"
    end
  end

  ## User channels
  #
  # Five policies, all TO authenticated:
  #
  #   lobby                                       SELECT  realtime.topic() ~* 'public:lobby'
  #   users receive on own channel                SELECT  realtime.topic() = 'user:' || auth.uid()
  #                                                       AND extension IN ('broadcast', 'presence')
  #   users receive on own channel (initplan)     the same with (select auth.uid())
  #   users send on own channel                   INSERT  WITH CHECK, the same expression
  #   users send on own channel (initplan)        the same with (select auth.uid())
  #
  # With the claims a Realtime join builds, auth.uid() is the sub as a uuid: NULL for a missing or
  # empty sub, an error for something that isn't a uuid. Postgres compares text by bytes, and uuid
  # prints as lowercase 8-4-4-4-12.

  describe "user channels, read" do
    @reads [
      # Topics, for a token whose sub is @uid
      %{name: "own uid", topic: "user:#{@uid}", sub: @uid, expect: @allow},
      %{name: "someone else's uid", topic: "user:#{@other_uid}", sub: @uid, expect: @deny},
      # uuid prints lowercase and texteq compares bytes
      %{name: "own uid in upper case", topic: "user:#{String.upcase(@uid)}", sub: @uid, expect: @deny},
      %{name: "the lobby topic", topic: "public:lobby", sub: @uid, expect: @allow},
      # ~* ignores case
      %{name: "the lobby topic in upper case", topic: "PUBLIC:LOBBY", sub: @uid, expect: @allow},
      # ~ is an unanchored substring match
      %{name: "the lobby topic inside another one", topic: "xpublic:lobbyy", sub: @uid, expect: @allow},
      %{name: "a topic that matches nothing", topic: "room:1", sub: @uid, expect: @deny},
      # How ~* folds non-ASCII letters depends on the database's collation, so it falls back, even for
      # a topic that can't match
      %{name: "a non-ASCII topic", topic: "public:lobby:é", sub: @uid, expect: @regex_non_ascii},
      %{name: "a non-ASCII topic that can't match", topic: "café", sub: @uid, expect: @regex_non_ascii},
      # The topic setting is '', which realtime.topic() turns into NULL: every comparison is NULL, and NULL denies
      %{name: "an empty topic", topic: "", sub: @uid, expect: @deny},

      # Subs, for the topic "user:" and the canonical uuid
      %{name: "sub in upper case", topic: "user:#{@uid}", sub: String.upcase(@uid), expect: @allow},
      %{name: "braced sub", topic: "user:#{@uid}", sub: "{#{@uid}}", expect: @allow},
      %{name: "unhyphenated sub", topic: "user:#{@uid}", sub: String.replace(@uid, "-", ""), expect: @allow},
      %{
        name: "sub with hyphens after every group",
        topic: "user:#{@uid}",
        sub: "a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11",
        expect: @allow
      },
      # uuid_in doesn't skip whitespace
      %{name: "sub with a leading space", topic: "user:#{@uid}", sub: " #{@uid}", expect: @invalid_uuid},
      # The legacy auth.uid() is nullif(sub, '')::uuid, so NULL, and NULL = ... is NULL, which denies.
      # supabase/auth's is coalesce(nullif(sub, ''), claims ->> 'sub')::uuid, and the claims have "sub": "", which
      # is not NULL: ''::uuid raises. (Realtime doesn't send an empty sub today, but a third-party JWT could.)
      %{name: "empty sub", topic: "user:#{@uid}", sub: "", expect: @deny, supabase_auth: @invalid_uuid},
      # No sub anywhere: NULL with both bodies
      %{name: "no sub", topic: "user:#{@uid}", sub: nil, expect: @deny},
      %{name: "no sub on the lobby topic", topic: "public:lobby", sub: nil, expect: @allow},
      # A sub that isn't a uuid, as a third-party auth provider sends: the cast raises where it is
      # reached, and there is nothing to decide the OR without it
      %{name: "sub that isn't a uuid", topic: "user:user_2abc", sub: "user_2abc", expect: @invalid_uuid},
      %{
        name: "sub that isn't a uuid, on a topic nothing matches",
        topic: "room:1",
        sub: "user_2abc",
        expect: @invalid_uuid
      },
      # ... and lobby is true, but that doesn't decide the OR: Postgres may have evaluated the failing
      # branch first, and raises, as measured
      %{
        name: "sub that isn't a uuid, on the lobby topic",
        topic: "public:lobby",
        sub: "user_2abc",
        expect: @invalid_uuid
      },

      # Roles. No policy is for anon, so there is no permissive policy and Postgres uses `false`
      %{name: "anon, own uid", topic: "user:#{@uid}", sub: @uid, role: "anon", expect: @deny},
      %{name: "anon, the lobby topic", topic: "public:lobby", sub: @uid, role: "anon", expect: @deny},
      # Not a role we model, it bypasses RLS
      %{
        name: "service_role",
        topic: "user:#{@uid}",
        sub: @uid,
        role: "service_role",
        expect: {:fallback, {:role, "service_role"}}
      }
    ]

    for %{name: name} = case_ <- @reads, extension <- ["broadcast", "presence"] do
      test "#{extension}: #{name}", %{catalogs: catalogs} do
        case_ = unquote(Macro.escape(case_))
        extension = unquote(extension)

        env =
          env(topic: case_.topic, sub: case_.sub, role: Map.get(case_, :role, "authenticated"), extension: extension)

        assert_all_variants(
          catalogs,
          &user_channel_policies/1,
          env,
          :read,
          case_.expect,
          Map.get(case_, :supabase_auth)
        )
      end
    end

    # Realtime doesn't check other extensions today, but the policy is only true for two
    test "an extension outside the list, own uid", %{catalogs: catalogs} do
      env = env(topic: "user:#{@uid}", sub: @uid, extension: "postgres_changes")
      assert_all_variants(catalogs, &user_channel_policies/1, env, :read, @deny)
    end

    # false AND <error> is false for the executor only if it evaluates the extension comparison first,
    # which the planner decides. Postgres 17 raises here on reads, so it is a fallback
    test "an extension outside the list, sub that isn't a uuid: the failing cast decides", %{catalogs: catalogs} do
      env = env(topic: "user:user_2abc", sub: "user_2abc", extension: "postgres_changes")
      assert_all_variants(catalogs, &user_channel_policies/1, env, :read, @invalid_uuid)
    end
  end

  describe "user channels, write" do
    @writes [
      %{name: "own uid", topic: "user:#{@uid}", sub: @uid, expect: @allow},
      %{name: "someone else's uid", topic: "user:#{@other_uid}", sub: @uid, expect: @deny},
      %{name: "own uid in upper case", topic: "user:#{String.upcase(@uid)}", sub: @uid, expect: @deny},
      # Only the receive side has a policy for the lobby
      %{name: "the lobby topic", topic: "public:lobby", sub: @uid, expect: @deny},
      %{name: "the lobby topic in upper case", topic: "PUBLIC:LOBBY", sub: @uid, expect: @deny},
      %{name: "the lobby topic inside another one", topic: "xpublic:lobbyy", sub: @uid, expect: @deny},
      # The send policies have no regex, so a non-ASCII topic is just a topic that isn't the user's
      %{name: "a non-ASCII topic", topic: "public:lobby:é", sub: @uid, expect: @deny},
      %{name: "an empty topic", topic: "", sub: @uid, expect: @deny},
      %{name: "sub in upper case", topic: "user:#{@uid}", sub: String.upcase(@uid), expect: @allow},
      %{name: "braced sub", topic: "user:#{@uid}", sub: "{#{@uid}}", expect: @allow},
      %{name: "unhyphenated sub", topic: "user:#{@uid}", sub: String.replace(@uid, "-", ""), expect: @allow},
      # See the read case
      %{name: "empty sub", topic: "user:#{@uid}", sub: "", expect: @deny, supabase_auth: @invalid_uuid},
      %{name: "no sub", topic: "user:#{@uid}", sub: nil, expect: @deny},
      %{name: "sub that isn't a uuid", topic: "user:user_2abc", sub: "user_2abc", expect: @invalid_uuid},
      # No policy is false, and both send policies fail: nothing to decide with
      %{
        name: "sub that isn't a uuid, on the lobby topic",
        topic: "public:lobby",
        sub: "user_2abc",
        expect: @invalid_uuid
      },
      %{name: "anon, own uid", topic: "user:#{@uid}", sub: @uid, role: "anon", expect: @deny},
      %{
        name: "service_role",
        topic: "user:#{@uid}",
        sub: @uid,
        role: "service_role",
        expect: {:fallback, {:role, "service_role"}}
      },
      # The extension is in the list for both, but not for others
      %{name: "own uid, presence", topic: "user:#{@uid}", sub: @uid, extension: "presence", expect: @allow},
      %{
        name: "own uid, an extension outside the list",
        topic: "user:#{@uid}",
        sub: @uid,
        extension: "persistence",
        expect: @deny
      },
      # The extension comparison is false, but the failing cast may be evaluated first
      %{
        name: "sub that isn't a uuid, an extension outside the list",
        topic: "user:user_2abc",
        sub: "user_2abc",
        extension: "persistence",
        expect: @invalid_uuid
      }
    ]

    for %{name: name} = case_ <- @writes do
      test "#{name}", %{catalogs: catalogs} do
        case_ = unquote(Macro.escape(case_))

        env =
          env(
            topic: case_.topic,
            sub: case_.sub,
            role: Map.get(case_, :role, "authenticated"),
            extension: Map.get(case_, :extension, "broadcast")
          )

        assert_all_variants(
          catalogs,
          &user_channel_policies/1,
          env,
          :write,
          case_.expect,
          Map.get(case_, :supabase_auth)
        )
      end
    end
  end

  describe "the same results with supabase/auth's auth.uid()" do
    # assert_all_variants runs every case above with both bodies. This one pins what differs.
    test "differs only for a sub that is an empty string, where supabase/auth's body raises", %{catalogs: catalogs} do
      for operation <- [:read, :write], version <- @versions do
        catalog = catalogs[version]
        env = env(topic: "user:#{@uid}", sub: "")

        legacy = snapshot(user_channel_policies(catalog), functions(catalog, :legacy))
        supabase_auth = snapshot(user_channel_policies(catalog), functions(catalog, :supabase_auth))

        assert SqlLogex.decide(legacy, env, operation) == @deny
        assert SqlLogex.decide(supabase_auth, env, operation) == @invalid_uuid
      end
    end

    # supabase/auth's body parses the claims even when the sub setting is set, as COALESCE can't skip an
    # argument that raises. The legacy body doesn't read the claims at all.
    test "falls back for claims that don't parse, even with the sub set", %{catalogs: catalogs} do
      catalog = catalogs["pg17"]
      env = env(topic: "user:#{@uid}", sub: @uid, claims: ~s({"sub":"#{@uid}","x":"\\u0000"}))

      legacy = snapshot(user_channel_policies(catalog), functions(catalog, :legacy))
      supabase_auth = snapshot(user_channel_policies(catalog), functions(catalog, :supabase_auth))

      assert SqlLogex.decide(legacy, env, :read) == @allow

      assert SqlLogex.decide(supabase_auth, env, :read) ==
               {:fallback, {:unsupported, {:raises, :untranslatable_character, "unsupported Unicode escape sequence"}}}
    end
  end

  ## Fallbacks before evaluating

  describe "fallbacks before evaluating" do
    setup %{catalogs: catalogs} do
      catalog = catalogs["pg17"]
      %{catalog: catalog, policies: user_channel_policies(catalog)}
    end

    test "the baseline decides", %{catalog: catalog, policies: policies} do
      snapshot = snapshot(policies, catalog.functions)
      assert SqlLogex.decide(snapshot, env(topic: "user:#{@uid}", sub: @uid), :read) == @allow
    end

    for role <- ["service_role", "postgres", "supabase_admin", "authenticator", "", "ANON"] do
      test "the role #{inspect(role)} is not modelled", %{catalog: catalog, policies: policies} do
        snapshot = snapshot(policies, catalog.functions)
        env = env(topic: "user:#{@uid}", sub: @uid, role: unquote(role))

        assert SqlLogex.decide(snapshot, env, :read) == {:fallback, {:role, unquote(role)}}
        assert SqlLogex.decide(snapshot, env, :write) == {:fallback, {:role, unquote(role)}}
      end
    end

    test "a missing role setting", %{catalog: catalog, policies: policies} do
      snapshot = snapshot(policies, catalog.functions)
      env = Env.new(%{}, %{})

      assert SqlLogex.decide(snapshot, env, :read) == {:fallback, {:role, nil}}
    end

    test "RLS disabled", %{catalog: catalog, policies: policies} do
      snapshot = snapshot(policies, catalog.functions, %{rls_enabled: false})
      assert SqlLogex.decide(snapshot, env(topic: "t", sub: @uid), :read) == {:fallback, :rls_disabled}
    end

    test "RLS forced", %{catalog: catalog, policies: policies} do
      snapshot = snapshot(policies, catalog.functions, %{rls_forced: true})
      assert SqlLogex.decide(snapshot, env(topic: "t", sub: @uid), :write) == {:fallback, :rls_forced}
    end

    test "a role that bypasses RLS", %{catalog: catalog, policies: policies} do
      roles = %{@roles | "authenticated" => %{bypass_rls: true, select: true, insert: true}}
      snapshot = snapshot(policies, catalog.functions, %{roles: roles})

      assert SqlLogex.decide(snapshot, env(topic: "t", sub: @uid), :read) == {:fallback, {:bypass_rls, "authenticated"}}
      # another role isn't affected
      assert SqlLogex.decide(snapshot, env(topic: "t", sub: @uid, role: "anon"), :read) == @deny
    end

    test "a role missing from the snapshot", %{catalog: catalog, policies: policies} do
      snapshot = snapshot(policies, catalog.functions, %{roles: Map.delete(@roles, "anon")})

      assert SqlLogex.decide(snapshot, env(topic: "t", role: "anon"), :read) ==
               {:fallback, {:role_not_in_snapshot, "anon"}}
    end

    test "a missing grant is a fallback for the operation it is needed for", %{catalog: catalog, policies: policies} do
      no_select = %{@roles | "authenticated" => %{bypass_rls: false, select: false, insert: true}}
      no_insert = %{@roles | "authenticated" => %{bypass_rls: false, select: true, insert: false}}
      env = env(topic: "user:#{@uid}", sub: @uid)

      # A write needs select too: realtime.authorize reads the table on every call, see the PolicySet moduledoc
      snapshot = snapshot(policies, catalog.functions, %{roles: no_select})
      assert SqlLogex.decide(snapshot, env, :read) == {:fallback, {:missing_grant, "authenticated", :select}}
      assert SqlLogex.decide(snapshot, env, :write) == {:fallback, {:missing_grant, "authenticated", :select}}

      snapshot = snapshot(policies, catalog.functions, %{roles: no_insert})
      assert SqlLogex.decide(snapshot, env, :read) == @allow
      assert SqlLogex.decide(snapshot, env, :write) == {:fallback, {:missing_grant, "authenticated", :insert}}

      # With neither, the one the write itself needs is reported
      none = %{@roles | "authenticated" => %{bypass_rls: false, select: false, insert: false}}
      snapshot = snapshot(policies, catalog.functions, %{roles: none})
      assert SqlLogex.decide(snapshot, env, :write) == {:fallback, {:missing_grant, "authenticated", :insert}}
    end

    test "a policy for a role that isn't modelled, for the command being decided", %{
      catalog: catalog,
      policies: policies
    } do
      extra = fn cmd -> policy("for_team", cmd: cmd, roles: ["team_member"], qual: "true", with_check: "true") end
      env = env(topic: "user:#{@uid}", sub: @uid)

      for {cmd, read, write} <- [
            {"r", {:fallback, {:unmodelled_policy_role, "for_team", "team_member"}}, @allow},
            {"a", @allow, {:fallback, {:unmodelled_policy_role, "for_team", "team_member"}}},
            {"*", {:fallback, {:unmodelled_policy_role, "for_team", "team_member"}},
             {:fallback, {:unmodelled_policy_role, "for_team", "team_member"}}},
            # not decided here at all
            {"w", @allow, @allow},
            {"d", @allow, @allow}
          ] do
        snapshot = snapshot(policies ++ [extra.(cmd)], catalog.functions)
        assert SqlLogex.decide(snapshot, env, :read) == read, "cmd #{cmd}"
        assert SqlLogex.decide(snapshot, env, :write) == write, "cmd #{cmd}"
      end
    end

    test "a policy naming several roles falls back if any is not modelled", %{catalog: catalog, policies: policies} do
      snapshot =
        snapshot(policies ++ [policy("p", roles: ["authenticated", "team_member"])], catalog.functions)

      assert SqlLogex.decide(snapshot, env(topic: "t", sub: @uid), :read) ==
               {:fallback, {:unmodelled_policy_role, "p", "team_member"}}
    end

    test "policies for public, anon, authenticated and service_role are fine", %{catalog: catalog, policies: policies} do
      extra =
        for role <- ["public", "anon", "authenticated", "service_role"],
            do: policy("for_#{role}", roles: [role], qual: "false")

      snapshot = snapshot(policies ++ extra, catalog.functions)

      assert SqlLogex.decide(snapshot, env(topic: "user:#{@uid}", sub: @uid), :read) == @allow
    end

    test "an applicable policy without the expression to evaluate", %{catalog: catalog, policies: policies} do
      read = policy("no_using", cmd: "r", qual: nil)
      write = policy("no_check", cmd: "a", qual: nil, with_check: nil)
      all = policy("no_expression", cmd: "*", qual: nil, with_check: nil)
      env = env(topic: "user:#{@uid}", sub: @uid)

      assert SqlLogex.decide(snapshot(policies ++ [read], catalog.functions), env, :read) ==
               {:fallback, {:policy_without_expression, "no_using"}}

      assert SqlLogex.decide(snapshot(policies ++ [write], catalog.functions), env, :write) ==
               {:fallback, {:policy_without_expression, "no_check"}}

      assert SqlLogex.decide(snapshot(policies ++ [all], catalog.functions), env, :read) ==
               {:fallback, {:policy_without_expression, "no_expression"}}

      # A write also needs the USING of the SELECT and ALL policies, see the PolicySet moduledoc
      assert SqlLogex.decide(snapshot(policies ++ [all], catalog.functions), env, :write) ==
               {:fallback, {:select_policy_unsupported, "no_expression"}}

      assert SqlLogex.decide(snapshot(policies ++ [read], catalog.functions), env, :write) ==
               {:fallback, {:select_policy_unsupported, "no_using"}}

      # a policy that doesn't apply doesn't matter
      assert SqlLogex.decide(snapshot(policies ++ [write], catalog.functions), env, :read) == @allow

      assert SqlLogex.decide(
               snapshot(policies ++ [policy("anon_only", roles: ["anon"], qual: nil)], catalog.functions),
               env,
               :read
             ) == @allow
    end

    test "anything that raises is a fallback", %{catalog: catalog} do
      broken = %Policy{
        name: "broken",
        cmd: "r",
        permissive: true,
        roles: ["authenticated"],
        using: {{:apply, SqlLogex.Value, :no_such_primitive, []}, :bool},
        with_check: nil
      }

      snapshot = %Snapshot{snapshot([], catalog.functions) | policies: [broken]}

      assert {:fallback, {:exception, message}} = SqlLogex.decide(snapshot, env(topic: "t"), :read)
      assert message =~ "no_such_primitive"

      assert {:fallback, {:exception, _}} =
               SqlLogex.decide(%Snapshot{snapshot | policies: :oops}, env(topic: "t"), :read)

      assert {:fallback, {:exception, _}} = SqlLogex.decide(snapshot([], []), :not_an_env, :read)
    end

    test "a table fact that isn't the expected boolean is the unsafe answer", %{catalog: catalog, policies: policies} do
      env = env(topic: "user:#{@uid}", sub: @uid)
      snapshot = snapshot(policies, catalog.functions)

      assert SqlLogex.decide(%Snapshot{snapshot | rls_enabled: nil}, env, :read) == {:fallback, :rls_disabled}
      assert SqlLogex.decide(%Snapshot{snapshot | rls_forced: nil}, env, :read) == {:fallback, :rls_forced}

      roles = %{"authenticated" => %{select: true, insert: true}}

      assert SqlLogex.decide(%Snapshot{snapshot | roles: roles}, env, :read) ==
               {:fallback, {:bypass_rls, "authenticated"}}

      roles = %{"authenticated" => %{bypass_rls: false}}

      assert SqlLogex.decide(%Snapshot{snapshot | roles: roles}, env, :read) ==
               {:fallback, {:missing_grant, "authenticated", :select}}

      assert SqlLogex.decide(%Snapshot{}, env, :read) == {:fallback, :rls_disabled}
    end
  end

  ## Combining policies

  describe "combining" do
    @topic_is_x "(realtime.topic() = 'x'::text)"
    @topic_is_y "(realtime.topic() = 'y'::text)"

    setup %{catalogs: catalogs} do
      %{functions: catalogs["pg17"].functions}
    end

    test "permissive policies are OR'd", %{functions: functions} do
      policies = [policy("a", qual: @topic_is_x), policy("b", qual: @topic_is_y)]

      assert decide_with(policies, functions, :read, "x") == @allow
      assert decide_with(policies, functions, :read, "y") == @allow
      assert decide_with(policies, functions, :read, "z") == @deny
    end

    test "restrictive policies are AND'd with the permissive ones", %{functions: functions} do
      policies = [
        policy("a", qual: "true"),
        policy("r1", permissive: false, qual: "(realtime.topic() <> 'x'::text)"),
        policy("r2", permissive: false, qual: "(realtime.topic() <> 'y'::text)")
      ]

      assert decide_with(policies, functions, :read, "z") == @allow
      assert decide_with(policies, functions, :read, "x") == @deny
      assert decide_with(policies, functions, :read, "y") == @deny
    end

    test "restrictive policies alone deny, and are never evaluated", %{functions: functions} do
      policies = [policy("r", permissive: false, qual: "true")]
      assert decide_with(policies, functions, :read, "x") == @deny

      # not even a restrictive policy we couldn't evaluate
      policies = [policy("r", permissive: false, qual: "(auth.email() = 'a'::text)")]
      assert decide_with(policies, functions, :read, "x") == @deny
    end

    test "no policy at all denies", %{functions: functions} do
      assert decide_with([], functions, :read, "x") == @deny
      assert decide_with([], functions, :write, "x") == @deny
    end

    test "NULL denies, for permissive and restrictive policies", %{functions: functions} do
      assert decide_with([policy("a", qual: "(realtime.topic() = NULL::text)")], functions, :read, "x") == @deny

      policies = [policy("a", qual: "true"), policy("r", permissive: false, qual: "(realtime.topic() = NULL::text)")]
      assert decide_with(policies, functions, :read, "x") == @deny
    end

    test "a NULL permissive policy next to a true one allows", %{functions: functions} do
      policies = [policy("a", qual: "(realtime.topic() = NULL::text)"), policy("b", qual: "true")]
      assert decide_with(policies, functions, :read, "x") == @allow
    end

    @unsupported_email {:fallback, {:unsupported, {:function, "auth.email", :not_in_snapshot}}}

    test "an unsupported policy makes the decision a fallback, whatever the others say", %{functions: functions} do
      policies = [policy("a", qual: "(auth.email() = 'a'::text)"), policy("b", qual: @topic_is_x)]

      assert decide_with(policies, functions, :read, "x") == @unsupported_email
      assert decide_with(policies, functions, :read, "y") == @unsupported_email

      # a restrictive policy that fails doesn't decide it either
      policies = [policy("a", qual: "(auth.email() = 'a'::text)"), policy("r", permissive: false, qual: @topic_is_y)]
      assert decide_with(policies, functions, :read, "x") == @unsupported_email
    end

    test "an expression that isn't boolean is unsupported", %{functions: functions} do
      policies = [policy("a", qual: "realtime.topic()")]

      assert decide_with(policies, functions, :read, "x") == {:fallback, {:unsupported, {:not_boolean, :text}}}
    end

    test "reads use USING and ignore WITH CHECK", %{functions: functions} do
      policies = [policy("a", cmd: "*", qual: @topic_is_x, with_check: @topic_is_y)]

      assert decide_with(policies, functions, :read, "x") == @allow
      assert decide_with(policies, functions, :read, "y") == @deny
    end

    test "writes use WITH CHECK, and USING for ALL policies that have none", %{functions: functions} do
      both = [policy("a", cmd: "*", qual: @topic_is_x, with_check: @topic_is_y)]
      assert decide_with(both, functions, :write, "y") == @allow
      assert decide_with(both, functions, :write, "x") == @deny

      using_only = [policy("a", cmd: "*", qual: @topic_is_x, with_check: nil)]
      assert decide_with(using_only, functions, :write, "x") == @allow
      assert decide_with(using_only, functions, :write, "y") == @deny

      insert = [policy("a", cmd: "a", qual: nil, with_check: @topic_is_x)]
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
      policies = [policy("for_anon", roles: ["anon"], qual: "true")]
      env = fn role -> env(topic: "x", sub: @uid, role: role) end

      assert SqlLogex.decide(snapshot(policies, functions), env.("anon"), :read) == @allow
      assert SqlLogex.decide(snapshot(policies, functions), env.("authenticated"), :read) == @deny

      policies = [policy("for_public", roles: ["public"], qual: "true")]
      assert SqlLogex.decide(snapshot(policies, functions), env.("anon"), :read) == @allow
      assert SqlLogex.decide(snapshot(policies, functions), env.("authenticated"), :read) == @allow

      policies = [policy("both", roles: ["anon", "authenticated"], qual: "true")]
      assert SqlLogex.decide(snapshot(policies, functions), env.("anon"), :read) == @allow
      assert SqlLogex.decide(snapshot(policies, functions), env.("authenticated"), :read) == @allow
    end

    test "the order of the policies doesn't matter", %{functions: functions} do
      policies = [
        policy("a", qual: "(auth.email() = 'a'::text)"),
        policy("b", qual: @topic_is_x),
        policy("r", permissive: false, qual: "true")
      ]

      for ordered <- [policies, Enum.reverse(policies)] do
        assert decide_with(ordered, functions, :read, "x") == @unsupported_email
      end
    end
  end

  ## Writes and the read statement of realtime.authorize

  describe "a write also needs the SELECT policies to be modelled" do
    @topic_x "(realtime.topic() = 'x'::text)"
    @unsupported_select "(auth.email() = 'a'::text)"

    setup %{catalogs: catalogs} do
      %{functions: catalogs["pg17"].functions}
    end

    defp insert_policy, do: policy("insert", cmd: "a", qual: nil, with_check: @topic_x)

    defp write_with(policies, functions, opts \\ []) do
      role = Keyword.get(opts, :role, "authenticated")
      sub = Keyword.get(opts, :sub, @uid)
      SqlLogex.decide(snapshot(policies, functions), env(topic: "x", sub: sub, role: role), :write)
    end

    test "a SELECT policy that is supported doesn't matter", %{functions: functions} do
      assert write_with([insert_policy(), policy("select", qual: @topic_x)], functions) == @allow
      assert write_with([insert_policy(), policy("select", qual: "false")], functions) == @allow
    end

    test "a SELECT policy with an unsupported expression is a fallback", %{functions: functions} do
      policies = [insert_policy(), policy("select_email", qual: @unsupported_select)]

      assert write_with(policies, functions) == {:fallback, {:select_policy_unsupported, "select_email"}}
      # even though the INSERT policy decides on its own
      assert write_with([insert_policy()], functions) == @allow
    end

    test "unsupported anywhere in the expression counts", %{functions: functions} do
      for qual <- [
            "(#{@topic_x} AND (auth.email() = 'a'::text))",
            "(#{@topic_x} OR (NOT (auth.email() = 'a'::text)))",
            "(realtime.topic() = ANY (ARRAY['a'::text, auth.email()]))",
            "COALESCE((auth.email() = 'a'::text), true)",
            "( SELECT true\n   FROM pg_sleep((1)::double precision) pg_sleep(pg_sleep))",
            "(private = true)"
          ] do
        policies = [insert_policy(), policy("select", qual: qual)]
        assert write_with(policies, functions) == {:fallback, {:select_policy_unsupported, "select"}}, qual
      end
    end

    test "a SELECT policy without a USING expression is a fallback", %{functions: functions} do
      policies = [insert_policy(), policy("select", qual: nil)]
      assert write_with(policies, functions) == {:fallback, {:select_policy_unsupported, "select"}}
    end

    test "an ALL policy counts for its USING, even if the write uses its WITH CHECK", %{functions: functions} do
      policies = [policy("all", cmd: "*", qual: @unsupported_select, with_check: @topic_x)]
      assert write_with(policies, functions) == {:fallback, {:select_policy_unsupported, "all"}}

      policies = [policy("all", cmd: "*", qual: nil, with_check: @topic_x)]
      assert write_with(policies, functions) == {:fallback, {:select_policy_unsupported, "all"}}

      policies = [policy("all", cmd: "*", qual: @topic_x, with_check: @topic_x)]
      assert write_with(policies, functions) == @allow
    end

    test "restrictive SELECT policies count too, even when they would not be evaluated", %{functions: functions} do
      policies = [insert_policy(), policy("restrictive", permissive: false, qual: @unsupported_select)]
      assert write_with(policies, functions) == {:fallback, {:select_policy_unsupported, "restrictive"}}
    end

    test "the first one is named", %{functions: functions} do
      policies = [
        insert_policy(),
        policy("a_fine", qual: @topic_x),
        policy("b_first", qual: @unsupported_select),
        policy("c_second", qual: nil)
      ]

      assert write_with(policies, functions) == {:fallback, {:select_policy_unsupported, "b_first"}}
    end

    test "only the policies that might apply to the role count", %{functions: functions} do
      policies = [
        policy("insert", cmd: "a", roles: ["anon", "authenticated"], qual: nil, with_check: @topic_x),
        policy("for_anon", roles: ["anon"], qual: @unsupported_select)
      ]

      assert write_with(policies, functions) == @allow

      assert write_with(policies, functions, role: "anon") ==
               {:fallback, {:select_policy_unsupported, "for_anon"}}

      # public applies to everyone
      policies = [insert_policy(), policy("for_public", roles: ["public"], qual: @unsupported_select)]
      assert write_with(policies, functions) == {:fallback, {:select_policy_unsupported, "for_public"}}
    end

    test "a policy for a role that isn't modelled might apply, by membership", %{functions: functions} do
      policies = [insert_policy(), policy("for_team", roles: ["team_member"], qual: @unsupported_select)]
      assert write_with(policies, functions) == {:fallback, {:select_policy_unsupported, "for_team"}}

      # one we can read can't fail the statement by being there
      policies = [insert_policy(), policy("for_team", roles: ["team_member"], qual: @topic_x)]
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

    test "a SELECT policy that raises for this input but is modelled doesn't count", %{functions: functions} do
      # Measured against Postgres 17: with no probe row to evaluate it for, a write-only call of
      # realtime.authorize doesn't raise for a policy like this
      raising = "((auth.uid())::text = 'x'::text)"
      policies = [insert_policy(), policy("select", qual: raising)]

      assert write_with(policies, functions, sub: "user_2abc") == @allow
      assert write_with(policies, functions) == @allow
    end

    test "a read is not affected, it evaluates the policies it needs", %{functions: functions} do
      policies = [insert_policy(), policy("select", qual: @topic_x)]
      assert SqlLogex.decide(snapshot(policies, functions), env(topic: "x", sub: @uid), :read) == @allow

      # the INSERT policy is not even looked at
      policies = [
        policy("insert", cmd: "a", qual: nil, with_check: @unsupported_select),
        policy("select", qual: @topic_x)
      ]

      assert SqlLogex.decide(snapshot(policies, functions), env(topic: "x", sub: @uid), :read) == @allow
    end

    test "the grants are checked first", %{functions: functions} do
      roles = %{@roles | "authenticated" => %{bypass_rls: false, select: false, insert: true}}
      policies = [insert_policy(), policy("select", qual: @unsupported_select)]

      assert SqlLogex.decide(snapshot(policies, functions, %{roles: roles}), env(topic: "x", sub: @uid), :write) ==
               {:fallback, {:missing_grant, "authenticated", :select}}
    end

    test "with no policy for SELECT at all, the write decides", %{functions: functions} do
      assert write_with([insert_policy()], functions) == @allow
      assert write_with([], functions) == @deny
    end

    test "the user-channel SELECT policies are modelled, so its writes decide", %{catalogs: catalogs} do
      for version <- @versions, variant <- [:legacy, :supabase_auth] do
        catalog = catalogs[version]
        snapshot = snapshot(user_channel_policies(catalog), functions(catalog, variant))

        assert SqlLogex.decide(snapshot, env(topic: "user:#{@uid}", sub: @uid), :write) == @allow,
               "#{version} #{variant}"
      end
    end
  end

  ## The generator policies of Realtime's test suite

  describe "claim-based policies" do
    @claim_cases [
      {"true", ~s({"broadcast_read":true}), @allow},
      {"the string true", ~s({"broadcast_read":"true"}), @allow},
      {"the string yes", ~s({"broadcast_read":"yes"}), @allow},
      {"false", ~s({"broadcast_read":false}), @deny},
      {"the string 0", ~s({"broadcast_read":"0"}), @deny},
      # ->> gives NULL, COALESCE turns it into false
      {"JSON null", ~s({"broadcast_read":null}), @deny},
      {"a missing key", ~s({"other":true}), @deny},
      {"an empty object", "{}", @deny},
      {"an array root", ~s(["broadcast_read"]), @deny},
      {"a string root", ~s("broadcast_read"), @deny},
      # jsonb keeps the last of duplicate keys
      {"duplicate keys", ~s({"broadcast_read":false,"broadcast_read":true}), @allow},
      # ::boolean raises
      {"a string that isn't a boolean", ~s({"broadcast_read":"maybe"}), @invalid_bool},
      # A number would be allowed by Postgres ('1' is true) but we don't render numbers
      {"a number", ~s({"broadcast_read":1}), {:fallback, {:unsupported, :jsonb_number_text}}},
      {"an object", ~s({"broadcast_read":{"a":1}}), {:fallback, {:unsupported, :jsonb_container_text}}},
      {"a NUL escape", ~s({"broadcast_read":"\\u0000"}),
       {:fallback, {:unsupported, {:raises, :untranslatable_character, "unsupported Unicode escape sequence"}}}},
      # The policy casts the setting itself, with no nullif: '' isn't JSON
      {"not JSON", "not json", @invalid_json},
      {"empty claims", "", @invalid_json}
    ]

    for {name, claims, expect} <- @claim_cases do
      test "broadcast_read is #{name}", %{catalogs: catalogs} do
        env = env(topic: "fixture_topic", extension: "broadcast", claims: unquote(claims))

        assert_all_variants(
          catalogs,
          &named(&1, ["generator_authenticated_read_broadcast_based_on_claim"]),
          env,
          :read,
          unquote(Macro.escape(expect))
        )
      end
    end

    test "the claim only matters on the topic and extension of the policy", %{catalogs: catalogs} do
      policies = &named(&1, ["generator_authenticated_read_broadcast_based_on_claim"])

      # another topic, or another extension, is false before the claim is looked at ...
      for {topic, extension} <- [{"other_topic", "broadcast"}, {"fixture_topic", "presence"}] do
        env = env(topic: topic, extension: extension, claims: ~s({"broadcast_read":true}))
        assert_all_variants(catalogs, policies, env, :read, @deny)

        # ... and one the claim can't change, though the claim here raises. That decides nothing,
        # as Postgres may have evaluated the cast first
        env = env(topic: topic, extension: extension, claims: ~s({"broadcast_read":"maybe"}))
        assert_all_variants(catalogs, policies, env, :read, @invalid_bool)

        env = env(topic: topic, extension: extension, claims: "not json")
        assert_all_variants(catalogs, policies, env, :read, @invalid_json)
      end
    end

    test "the presence policy reads presence_read", %{catalogs: catalogs} do
      policies = &named(&1, ["generator_authenticated_read_presence_based_on_claim"])
      env = &env(topic: "fixture_topic", extension: "presence", claims: &1)

      assert_all_variants(catalogs, policies, env.(~s({"presence_read":true})), :read, @allow)
      assert_all_variants(catalogs, policies, env.(~s({"broadcast_read":true})), :read, @deny)
    end

    test "with the other policies on top, a true one doesn't decide", %{catalogs: catalogs} do
      policies =
        &named(&1, ["generator_authenticated_read_broadcast_based_on_claim", "generator_authenticated_read_broadcast"])

      env = env(topic: "fixture_topic", extension: "broadcast", claims: ~s({"broadcast_read":"maybe"}))

      assert_all_variants(catalogs, policies, env, :read, @invalid_bool)
    end
  end

  describe "generator policies" do
    test "topic and extension", %{catalogs: catalogs} do
      read = &named(&1, ["generator_authenticated_read_broadcast"])
      write = &named(&1, ["generator_authenticated_write_broadcast"])

      for {topic, extension, expect} <- [
            {"fixture_topic", "broadcast", @allow},
            {"fixture_topic", "presence", @deny},
            {"other", "broadcast", @deny},
            {"fixture_topic ", "broadcast", @deny},
            {"FIXTURE_TOPIC", "broadcast", @deny}
          ] do
        env = env(topic: topic, extension: extension)
        assert_all_variants(catalogs, read, env, :read, expect)
        assert_all_variants(catalogs, write, env, :write, expect)
      end
    end

    test "extension lists", %{catalogs: catalogs} do
      read = &named(&1, ["generator_authenticated_read_broadcast_and_presence"])

      write =
        &named(&1, ["generator_authenticated_write_broadcast_and_presence", "generator_authenticated_write_persistence"])

      for {extension, expect} <- [{"broadcast", @allow}, {"presence", @allow}, {"other", @deny}] do
        env = env(topic: "fixture_topic", extension: extension)
        assert_all_variants(catalogs, read, env, :read, expect)
        assert_all_variants(catalogs, write, env, :write, expect)
      end

      # the other write policy is for persistence
      env = env(topic: "fixture_topic", extension: "persistence")
      assert_all_variants(catalogs, write, env, :write, @allow)
    end

    test "true policies allow everything", %{catalogs: catalogs} do
      env = env(topic: "anything", extension: "presence")

      assert_all_variants(catalogs, &named(&1, ["generator_authenticated_all_topic_read"]), env, :read, @allow)
      assert_all_variants(catalogs, &named(&1, ["generator_authenticated_all_topic_insert"]), env, :write, @allow)
    end

    test "a policy that matches on the sub", %{catalogs: catalogs} do
      sub = "c0ffee00-1111-4222-8333-444455556666"
      read = &named(&1, ["generator_authenticated_read_matching_user_sub"])
      write = &named(&1, ["generator_authenticated_write_matching_user_sub"])

      for {sub_in_token, expect} <- [
            {sub, @allow},
            # uuid_out prints lowercase
            {String.upcase(sub), @allow},
            {"{#{sub}}", @allow},
            {@uid, @deny},
            {nil, @deny},
            {"user_2abc", @invalid_uuid}
          ] do
        env = env(topic: "t", sub: sub_in_token)
        assert_all_variants(catalogs, read, env, :read, expect)
        assert_all_variants(catalogs, write, env, :write, expect)
      end
    end

    test "a policy on topic, extension and sub", %{catalogs: catalogs} do
      policies = &named(&1, ["generator_authenticated_read_presence_for_sub"])
      sub = "c0ffee00-1111-4222-8333-444455556666"

      assert_all_variants(
        catalogs,
        policies,
        env(topic: "fixture_topic", extension: "presence", sub: sub),
        :read,
        @allow
      )

      assert_all_variants(
        catalogs,
        policies,
        env(topic: "fixture_topic", extension: "presence", sub: @uid),
        :read,
        @deny
      )

      assert_all_variants(catalogs, policies, env(topic: "other", extension: "presence", sub: sub), :read, @deny)

      assert_all_variants(
        catalogs,
        policies,
        env(topic: "fixture_topic", extension: "broadcast", sub: sub),
        :read,
        @deny
      )

      # the cast of auth.uid() fails, unless the topic or extension is wrong first
      assert_all_variants(
        catalogs,
        policies,
        env(topic: "fixture_topic", extension: "presence", sub: "x"),
        :read,
        @invalid_uuid
      )

      assert_all_variants(
        catalogs,
        policies,
        env(topic: "other", extension: "presence", sub: "x"),
        :read,
        @invalid_uuid
      )
    end

    test "policies on the role, for public", %{catalogs: catalogs} do
      read = &named(&1, ["generator_read_matching_user_role"])
      write = &named(&1, ["generator_write_matching_user_role"])

      # auth.role() is the role of the token, which is also the role the probe runs as
      for {role, expect} <- [{"authenticated", @allow}, {"anon", @deny}] do
        env = env(topic: "t", role: role)
        assert_all_variants(catalogs, read, env, :read, expect)
        assert_all_variants(catalogs, write, env, :write, expect)
      end
    end

    test "a restrictive policy we can't evaluate", %{catalogs: catalogs} do
      policies = &named(&1, ["generator_authenticated_all_topic_read", "generator_slow_read"])

      # true AND unsupported: nothing to decide with
      env = env(topic: "t")
      assert_all_variants(catalogs, policies, env, :read, @slow_unsupported)

      policies = &named(&1, ["generator_authenticated_read_broadcast", "generator_slow_read"])

      # false AND unsupported: nothing to decide with either
      env = env(topic: "other")
      assert_all_variants(catalogs, policies, env, :read, @slow_unsupported)

      # no permissive policy applies for write... the slow write is restrictive too
      policies = &named(&1, ["generator_slow_write"])
      assert_all_variants(catalogs, policies, env(topic: "t"), :write, @deny)

      policies = &named(&1, ["generator_authenticated_all_topic_insert", "generator_slow_write"])
      assert_all_variants(catalogs, policies, env(topic: "t"), :write, @slow_unsupported)
    end

    test "a broken permissive policy decides nothing, whatever the others say", %{catalogs: catalogs} do
      broken = "generator_broken_read_presence"
      unsupported = {:fallback, {:unsupported, {:function, "public.test_log_error", :not_allowlisted}}}

      for policies <- [
            &named(&1, [broken, "generator_authenticated_all_topic_read"]),
            &named(&1, [broken, "generator_authenticated_read_broadcast"])
          ] do
        assert_all_variants(catalogs, policies, env(topic: "t"), :read, unsupported)
      end
    end

    test "ALL policy with only USING", %{catalogs: catalogs} do
      policies = &named(&1, ["grammar_all_using_only"])

      assert_all_variants(catalogs, policies, env(topic: "x"), :read, @allow)
      assert_all_variants(catalogs, policies, env(topic: "x"), :write, @allow)
      assert_all_variants(catalogs, policies, env(topic: "y"), :read, @deny)
      assert_all_variants(catalogs, policies, env(topic: "y"), :write, @deny)
    end

    test "restrictive policy of the grammar", %{catalogs: catalogs} do
      policies = &named(&1, ["generator_authenticated_all_topic_read", "grammar_restrictive"])

      assert_all_variants(catalogs, policies, env(topic: "x"), :read, @allow)
      assert_all_variants(catalogs, policies, env(topic: "y"), :read, @deny)
    end

    test "every policy of the fixtures can be decided or falls back, without raising", %{catalogs: catalogs} do
      for version <- @versions, variant <- [:legacy, :supabase_auth], policy <- catalogs[version].policies do
        for role <- ["anon", "authenticated"], operation <- [:read, :write] do
          snapshot = snapshot([policy_attrs(policy)], functions(catalogs[version], variant))
          decision = SqlLogex.decide(snapshot, env(topic: "fixture_topic", sub: @uid, role: role), operation)

          refute match?({:fallback, {:exception, _}}, decision), "#{version} #{policy.name}"
        end
      end
    end
  end
end
