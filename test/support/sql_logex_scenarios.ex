defmodule SqlLogexScenarios do
  @moduledoc """
  Scenarios on `realtime.messages`, which `Realtime.Tenants.SqlLogexDifferentialTest` runs through
  `realtime.authorize`.

  A scenario is a set of policies, an environment (the settings that Realtime sets on a join, and
  the row), and the extensions it asks for. Each extension is asked for as a read and as a write,
  with the key `{operation, extension}`.

  sql_logex has a copy of these scenarios as its worked example
  (`sql_logex/test/support/realtime_scenarios.ex`), with more scenarios about the internals of the
  library. The two copies do not have to stay equal.
  """

  @own "c0ffee00-1111-4222-8333-444455556666"
  @other "deadbeef-0000-4000-8000-000000000001"

  # What realtime.authorize is called with by Authorization.authorize/5, for reads and writes
  @extensions ["broadcast", "presence"]

  @headers ~s({"x-client-info":"supabase-js/2.0"})

  # How the bodies of auth.uid()/auth.role() are called in test names
  @flavor_labels %{legacy: "legacy", supabase_auth: "supabase/auth"}

  @doc "How a body of `auth.uid()` and `auth.role()` is called in test names."
  @spec flavor_label(:legacy | :supabase_auth) :: String.t()
  def flavor_label(flavor), do: Map.fetch!(@flavor_labels, flavor)

  ## The environment of a case: what Realtime sets on a join, and the row

  @doc """
  The environment of a case. `sub`, `topic` and `extension` are as in a join, and nil is NULL.
  `claims` is the JSON text, built from the role and the sub unless given (as text, or as a map to
  encode). `extra_claims` are added to the built claims. The row has the topic and the extension,
  unless `row_topic` is given.
  """
  @spec env(keyword()) :: map()
  def env(opts) do
    role = Keyword.get(opts, :role, "authenticated")
    topic = Keyword.get(opts, :topic, "room:1")
    sub = Keyword.get(opts, :sub, @own)

    claims =
      case Keyword.fetch(opts, :claims) do
        {:ok, claims} when is_map(claims) ->
          JSON.encode!(claims)

        {:ok, claims} ->
          claims

        :error ->
          %{"role" => role}
          |> then(&if sub, do: Map.put(&1, "sub", sub), else: &1)
          |> Map.merge(Keyword.get(opts, :extra_claims, %{}))
          |> JSON.encode!()
      end

    %{
      role: role,
      topic: topic,
      row_topic: Keyword.get(opts, :row_topic, topic),
      extension: Keyword.get(opts, :extension, "broadcast"),
      sub: sub,
      claim_role: Keyword.get(opts, :claim_role, role),
      claims: claims,
      headers: Keyword.get(opts, :headers, @headers)
    }
  end

  @doc "The `SqlLogex.Env` of an environment, for one extension."
  @spec logex_env(map(), String.t()) :: SqlLogex.Env.t()
  def logex_env(env, extension) do
    SqlLogex.Env.new(
      %{
        "role" => env.role,
        "realtime.topic" => env.topic,
        "request.jwt.claims" => env.claims,
        "request.jwt.claim.sub" => env.sub,
        "request.jwt.claim.role" => env.claim_role,
        "request.headers" => env.headers
      },
      %{"topic" => text(env.row_topic), "extension" => text(extension)}
    )
  end

  defp text(nil), do: nil
  defp text(value), do: {:text, value}

  ## Scenarios

  # name, group and the options of a scenario:
  #   policies:   CREATE POLICY statements, run after the ones that are on the table are dropped
  #   setup:      statements run before them
  #   env:        see env/1
  #   functions:  :legacy | :supabase_auth, the bodies of auth.uid() and auth.role()
  #   extensions: what is asked for, both as read and write extensions
  defp scenario(group, name, policies, env_opts, opts \\ []) do
    env = env(env_opts)
    functions = Keyword.get(opts, :functions, :legacy)
    extensions = Keyword.get(opts, :extensions, @extensions)

    %{
      group: group,
      name: name,
      setup: functions_setup(functions) ++ Keyword.get(opts, :setup, []),
      policies: policies,
      questions:
        for(
          operation <- [:read, :write],
          extension <- extensions,
          do: {{operation, extension}, operation, logex_env(env, extension)}
        ),
      detail: "functions: #{flavor_label(functions)}",
      env: env,
      extensions: extensions
    }
  end

  # The legacy bodies of auth.uid() and auth.role() are the ones of the supabase/postgres image,
  # supabase/auth's are what production projects run
  defp functions_setup(:legacy), do: [SqlLogexPolicies.auth_jwt_statement()]

  defp functions_setup(:supabase_auth),
    do: [SqlLogexPolicies.auth_jwt_statement(), SqlLogexPolicies.supabase_auth_functions_statement()]

  defp policy_sql(name, definition), do: ~s(CREATE POLICY "#{name}" ON realtime.messages #{definition})

  @doc "User channels. The topics are for a user whose sub is the own uuid, and the subs are spellings of it."
  @spec user_channel_grid(:plain | :initplan, :legacy | :supabase_auth) :: [map()]
  def user_channel_grid(form, flavor) do
    policies = SqlLogexPolicies.user_channel_policies(form)

    topics = [
      {"own uid", "user:#{@own}"},
      {"other uid", "user:#{@other}"},
      {"own uid in upper case", "user:#{String.upcase(@own)}"},
      {"lobby", "public:lobby"},
      {"lobby in upper case", "PUBLIC:LOBBY"},
      {"lobby inside another topic", "xpublic:lobbyy"},
      {"non-ASCII", "public:lobby:é"},
      {"non-ASCII, matches nothing", "café"},
      {"empty", ""},
      {"user: and nothing", "user:"},
      {"room", "room:1"}
    ]

    subs = [
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
      for {topic_label, topic} <- topics, {sub_label, sub} <- subs do
        {"authenticated", topic_label, topic, sub_label, sub, []}
      end

    # No policy is for these, so only a few combinations
    other_roles =
      for role <- ["anon", "service_role"],
          {topic_label, topic} <- [{"own uid", "user:#{@own}"}, {"lobby", "public:lobby"}, {"empty", ""}],
          {sub_label, sub} <- [{"canonical", @own}, {"missing", nil}, {"not a uuid", "user_2abc"}] do
        {role, topic_label, topic, sub_label, sub, []}
      end

    # Claims that jsonb doesn't take as they are. supabase/auth's auth.uid() reads them when the sub is empty
    claim_variants = [
      {"NUL in a claim", [extra_claims: %{"note" => "a" <> <<0>> <> "b"}]},
      {"nested and numeric claims", [extra_claims: %{"n" => 1.5, "m" => %{"a" => [1, nil]}, "t" => true}]},
      {"duplicate sub in the claims", [claims: ~s({"role":"authenticated","sub":"#{@other}","sub":"#{@own}"})]}
    ]

    claims =
      for {claims_label, claim_opts} <- claim_variants,
          {topic_label, topic} <- [{"own uid", "user:#{@own}"}, {"lobby", "public:lobby"}],
          {sub_label, sub} <- [{"canonical", @own}, {"missing", nil}, {"empty", ""}] do
        {"authenticated", topic_label, topic, "#{sub_label}, #{claims_label}", sub, claim_opts}
      end

    for {role, topic_label, topic, sub_label, sub, claim_opts} <- full ++ other_roles ++ claims do
      scenario(
        "user channels #{form}, #{flavor_label(flavor)}",
        "user channels #{form} (#{flavor_label(flavor)}) #{role}, topic: #{topic_label}, sub: #{sub_label}",
        policies,
        Keyword.merge([role: role, topic: topic, sub: sub], claim_opts),
        functions: flavor
      )
    end
  end

  @doc "The policies of `Generators.policy_query/2`, see `SqlLogexPolicies.generator_statements/2`."
  @spec generator_scenarios() :: [map()]
  def generator_scenarios do
    generators = fn names, params -> SqlLogexPolicies.generator_statements(names, params) end

    # OR REPLACE: the database can have it already
    broken_setup = [
      "CREATE OR REPLACE FUNCTION public.test_log_error() RETURNS boolean AS $$ BEGIN RAISE EXCEPTION 'test error'; END $$ LANGUAGE plpgsql"
    ]

    topic_specific =
      for {label, names} <- [
            {"broadcast", [:authenticated_read_broadcast, :authenticated_write_broadcast]},
            {"presence", [:authenticated_read_presence, :authenticated_write_presence]},
            {"broadcast and presence",
             [:authenticated_read_broadcast_and_presence, :authenticated_write_broadcast_and_presence]},
            {"broadcast and presence, each",
             [
               :authenticated_read_broadcast,
               :authenticated_read_presence,
               :authenticated_write_broadcast,
               :authenticated_write_presence
             ]},
            {"write persistence", [:authenticated_write_persistence, :authenticated_write_broadcast]}
          ],
          role <- ["authenticated", "anon"],
          topic <- ["t1", "t2", "", "T1", "t1 "] do
        scenario("generators", "#{label}, #{role}, topic #{inspect(topic)}", generators.(names, %{topic: "t1"}),
          role: role,
          topic: topic
        )
      end

    for_sub =
      for sub <- [@own, @other, String.upcase(@own), "{#{@own}}", nil, "", "user_2abc"],
          topic <- ["t1", "t2"],
          flavor <- [:legacy, :supabase_auth] do
        scenario(
          "generators",
          "presence for sub, sub #{inspect(sub)}, topic #{topic} (#{flavor_label(flavor)})",
          generators.([:authenticated_read_presence_for_sub], %{topic: "t1", sub: @own}),
          [topic: topic, sub: sub],
          functions: flavor
        )
      end

    claim_policies =
      generators.(
        [:authenticated_read_broadcast_based_on_claim, :authenticated_read_presence_based_on_claim],
        %{topic: "t1"}
      )

    claims =
      for {label, json} <- [
            {"true", ~s({"broadcast_read":true,"presence_read":true})},
            {"false", ~s({"broadcast_read":false,"presence_read":false})},
            {"missing", ~s({"role":"authenticated"})},
            {"strings", ~s({"broadcast_read":"true","presence_read":"yes"})},
            {"string 0", ~s({"broadcast_read":"0","presence_read":"off"})},
            {"null", ~s({"broadcast_read":null,"presence_read":null})},
            {"mixed", ~s({"broadcast_read":true,"presence_read":false})},
            {"maybe", ~s({"broadcast_read":"maybe","presence_read":"maybe"})},
            {"one maybe", ~s({"broadcast_read":true,"presence_read":"maybe"})},
            {"numbers", ~s({"broadcast_read":1,"presence_read":0})},
            {"objects", ~s({"broadcast_read":{"a":1},"presence_read":[]})},
            {"duplicate keys",
             ~s({"broadcast_read":false,"broadcast_read":true,"presence_read":true,"presence_read":false})},
            {"array root", ~s(["broadcast_read"])},
            {"string root", ~s("broadcast_read")},
            {"empty object", "{}"},
            {"NUL escape", ~s({"broadcast_read":"\\u0000","presence_read":true})},
            {"NUL escape elsewhere", ~s({"x":"\\u0000","broadcast_read":true})},
            {"not json", "not json"},
            {"empty claims", ""}
          ],
          topic <- ["t1", "t2"] do
        scenario("generators", "claims #{label}, topic #{topic}", claim_policies, topic: topic, claims: json)
      end

    matching_sub =
      for sub <- [@own, @other, String.upcase(@own), "{#{@own}}", String.replace(@own, "-", ""), nil, "", "user_2abc"],
          flavor <- [:legacy, :supabase_auth] do
        scenario(
          "generators",
          "matching user sub, sub #{inspect(sub)} (#{flavor_label(flavor)})",
          generators.([:authenticated_read_matching_user_sub, :authenticated_write_matching_user_sub], %{sub: @own}),
          [sub: sub],
          functions: flavor
        )
      end

    matching_role =
      for role <- ["authenticated", "anon", "service_role"], flavor <- [:legacy, :supabase_auth] do
        scenario(
          "generators",
          "matching user role, #{role} (#{flavor_label(flavor)})",
          generators.([:read_matching_user_role, :write_matching_user_role], %{role: "authenticated"}),
          [role: role],
          functions: flavor
        )
      end

    everything =
      for role <- ["authenticated", "anon"], topic <- ["t1", ""] do
        scenario(
          "generators",
          "all topics, #{role}, topic #{inspect(topic)}",
          generators.([:authenticated_all_topic_read, :authenticated_all_topic_insert], %{}),
          role: role,
          topic: topic
        )
      end

    # A policy that raises. One of them next to a policy that is true: Postgres evaluates the
    # permissive ones in reverse name order (so the failing one first) but folds `x OR true`.
    broken =
      for {label, names} <- [
            {"alone", [:broken_read_presence, :broken_write_presence]},
            {"with a true policy",
             [
               :broken_read_presence,
               :broken_write_presence,
               :authenticated_all_topic_read,
               :authenticated_all_topic_insert
             ]}
          ] do
        scenario("generators", "broken policies #{label}", generators.(names, %{}), [], setup: broken_setup)
      end

    topic_specific ++ for_sub ++ claims ++ matching_sub ++ matching_role ++ everything ++ broken
  end

  @doc "How policies combine: permissive and restrictive, commands, roles, NULL, and what the library does not model."
  @spec combination_scenarios() :: [map()]
  def combination_scenarios do
    is_x = "realtime.topic() = 'x'"
    is_y = "realtime.topic() = 'y'"

    sets = [
      {"permissive policies are OR'd",
       [
         policy_sql("a", "FOR SELECT TO authenticated USING (#{is_x})"),
         policy_sql("b", "FOR SELECT TO authenticated USING (#{is_y})"),
         policy_sql("c", "FOR INSERT TO authenticated WITH CHECK (#{is_x})"),
         policy_sql("d", "FOR INSERT TO authenticated WITH CHECK (#{is_y})")
       ]},
      {"restrictive next to a permissive policy",
       [
         policy_sql("a", "FOR SELECT TO authenticated USING (true)"),
         policy_sql("r1", "AS RESTRICTIVE FOR SELECT TO authenticated USING (realtime.topic() <> 'x')"),
         policy_sql("r2", "AS RESTRICTIVE FOR SELECT TO authenticated USING (realtime.topic() <> 'y')"),
         policy_sql("c", "FOR INSERT TO authenticated WITH CHECK (true)"),
         policy_sql("r3", "AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (realtime.topic() <> 'x')")
       ]},
      {"restrictive policies alone",
       [
         policy_sql("r1", "AS RESTRICTIVE FOR SELECT TO authenticated USING (true)"),
         policy_sql("r2", "AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (true)")
       ]},
      {"no policy", []},
      {"NULL",
       [
         policy_sql("a", "FOR SELECT TO authenticated USING (realtime.topic() = NULL)"),
         policy_sql("b", "FOR INSERT TO authenticated WITH CHECK (realtime.topic() = NULL)")
       ]},
      {"NULL next to a true policy",
       [
         policy_sql("a", "FOR SELECT TO authenticated USING (realtime.topic() = NULL)"),
         policy_sql("b", "FOR SELECT TO authenticated USING (#{is_x})"),
         policy_sql("c", "FOR INSERT TO authenticated WITH CHECK (realtime.topic() = NULL)"),
         policy_sql("d", "FOR INSERT TO authenticated WITH CHECK (#{is_x})")
       ]},
      {"NULL in a restrictive policy",
       [
         policy_sql("a", "FOR SELECT TO authenticated USING (true)"),
         policy_sql("r", "AS RESTRICTIVE FOR SELECT TO authenticated USING (extension = NULL)"),
         policy_sql("c", "FOR INSERT TO authenticated WITH CHECK (true)"),
         policy_sql("s", "AS RESTRICTIVE FOR INSERT TO authenticated WITH CHECK (extension = NULL)")
       ]},
      {"FOR ALL with USING only", [policy_sql("a", "FOR ALL TO authenticated USING (#{is_x})")]},
      {"FOR ALL with USING and WITH CHECK",
       [policy_sql("a", "FOR ALL TO authenticated USING (#{is_x}) WITH CHECK (#{is_y})")]},
      {"FOR INSERT only", [policy_sql("a", "FOR INSERT TO authenticated WITH CHECK (#{is_x})")]},
      {"FOR SELECT only", [policy_sql("a", "FOR SELECT TO authenticated USING (#{is_x})")]},
      {"UPDATE and DELETE policies",
       [
         policy_sql("a", "FOR UPDATE TO authenticated USING (true) WITH CHECK (true)"),
         policy_sql("b", "FOR DELETE TO authenticated USING (true)")
       ]},
      {"a policy for anon", [policy_sql("a", "FOR ALL TO anon USING (true)")]},
      {"a policy for public", [policy_sql("a", "FOR ALL USING (#{is_x})")]},
      {"a policy for anon and authenticated", [policy_sql("a", "FOR ALL TO anon, authenticated USING (#{is_x})")]},
      {"a policy for service_role", [policy_sql("a", "FOR ALL TO service_role USING (true)")]},
      {"a restrictive policy for another role",
       [
         policy_sql("a", "FOR ALL TO authenticated, anon USING (true)"),
         policy_sql("r", "AS RESTRICTIVE FOR ALL TO anon USING (false)")
       ]},
      {"a mix of cmd for one name",
       [
         policy_sql("a", "FOR SELECT TO authenticated USING (true)"),
         policy_sql("b", "FOR ALL TO authenticated USING (false) WITH CHECK (true)")
       ]},
      {"the extension",
       [
         policy_sql("a", "FOR ALL TO authenticated USING (extension = 'broadcast')"),
         policy_sql("b", "FOR ALL TO authenticated USING (extension = 'presence' AND #{is_x})")
       ]},
      {"unsupported next to a decisive policy",
       [
         policy_sql("a", "FOR ALL TO authenticated USING (lower(realtime.topic()) = 'x')"),
         policy_sql("b", "FOR ALL TO authenticated USING (#{is_x})")
       ]},
      {"unsupported alone", [policy_sql("a", "FOR ALL TO authenticated USING (lower(realtime.topic()) = 'x')")]},
      {"a failing restrictive policy next to an unsupported one",
       [
         policy_sql("a", "FOR ALL TO authenticated USING (lower(realtime.topic()) = 'x')"),
         policy_sql("r", "AS RESTRICTIVE FOR ALL TO authenticated USING (#{is_y})")
       ]},
      {"unsupported restrictive policy",
       [
         policy_sql("a", "FOR ALL TO authenticated USING (#{is_x})"),
         policy_sql("r", "AS RESTRICTIVE FOR ALL TO authenticated USING (lower(realtime.topic()) = 'x')")
       ]},
      {"a boolean test the parser doesn't read",
       [policy_sql("a", "FOR ALL TO authenticated USING ((realtime.topic() = 'x') IS NOT FALSE)")]},
      # The probe row has the defaults of the other columns, which aren't modelled
      {"another column", [policy_sql("a", "FOR ALL TO authenticated USING (private = false)")]},
      {"another column or the topic",
       [policy_sql("a", "FOR ALL TO authenticated USING (event IS NULL OR realtime.topic() = 'x')")]},
      {"another column and the topic",
       [policy_sql("a", "FOR ALL TO authenticated USING (event IS NOT NULL AND realtime.topic() = 'x')")]},
      {"a function the snapshot doesn't have",
       [policy_sql("a", "FOR ALL TO authenticated USING (auth.email() IS NULL)")]}
    ]

    for {label, policies} <- sets, role <- ["authenticated", "anon"], topic <- ["x", "y", "z", ""] do
      scenario("combination", "#{label}, #{role}, topic #{inspect(topic)}", policies, role: role, topic: topic)
    end
  end

  @doc """
  Everything the library doesn't model has to be a fallback, not an answer. The setups change the
  database in the transaction of the scenario, and roll back with it.
  """
  @spec snapshot_scenarios(pos_integer()) :: [map()]
  def snapshot_scenarios(server_version_num) do
    policies = [
      policy_sql("a", "FOR SELECT TO authenticated, anon USING (realtime.topic() = 'x')"),
      policy_sql("b", "FOR INSERT TO authenticated, anon WITH CHECK (realtime.topic() = 'x')")
    ]

    setups = [
      {"baseline", []},
      {"RLS disabled", ["ALTER TABLE realtime.messages DISABLE ROW LEVEL SECURITY"]},
      {"RLS forced", ["ALTER TABLE realtime.messages FORCE ROW LEVEL SECURITY"]},
      {"no INSERT for authenticated", ["REVOKE INSERT ON realtime.messages FROM authenticated"]},
      {"no INSERT for anon", ["REVOKE INSERT ON realtime.messages FROM anon"]},
      {"authenticated bypasses RLS", ["ALTER ROLE authenticated BYPASSRLS"]},
      {"anon bypasses RLS", ["ALTER ROLE anon BYPASSRLS"]},
      {"a policy for a role authenticated is a member of",
       [
         "CREATE ROLE sql_logex_team NOLOGIN",
         "GRANT sql_logex_team TO authenticated",
         policy_sql("team", "FOR ALL TO sql_logex_team USING (true) WITH CHECK (true)")
       ]},
      {"a policy for a role authenticated is not a member of",
       [
         "CREATE ROLE sql_logex_team NOLOGIN",
         policy_sql("team", "FOR ALL TO sql_logex_team USING (true) WITH CHECK (true)")
       ]}
    ]

    # GRANT ... WITH INHERIT is PG16 syntax
    setups =
      if server_version_num >= 160_000 do
        setups ++
          [
            {"a policy for a role authenticated is a member of, without inheritance",
             [
               "CREATE ROLE sql_logex_team NOLOGIN",
               "GRANT sql_logex_team TO authenticated WITH INHERIT FALSE",
               policy_sql("team", "FOR ALL TO sql_logex_team USING (true) WITH CHECK (true)")
             ]}
          ]
      else
        setups
      end

    for {label, setup} <- setups, role <- ["authenticated", "anon", "service_role"], topic <- ["x", "y"] do
      {extra_policies, setup} = Enum.split_with(setup, &String.starts_with?(&1, "CREATE POLICY"))

      scenario(
        "snapshot",
        "#{label}, #{role}, topic #{inspect(topic)}",
        policies ++ extra_policies,
        [role: role, topic: topic],
        setup: setup
      )
    end
  end

  @doc """
  A write reads the table too: the SELECT of the call runs in every call, write-only calls
  included (`write_plans_select: true`). So whatever makes that SELECT fail makes the writes fail:
  a missing SELECT privilege, and a SELECT policy that Postgres can't plan. The library decides a
  write only from what it can read of the SELECT policies: it falls back for a missing grant, and
  for a policy it doesn't fully model, see `SqlLogex.PolicySet`.
  """
  @spec select_dependent_scenarios() :: [map()]
  def select_dependent_scenarios do
    insert_policy = policy_sql("insert", "FOR INSERT TO authenticated, anon WITH CHECK (realtime.topic() = 'x')")

    revokes = [
      {"no SELECT for authenticated", ["REVOKE SELECT ON realtime.messages FROM authenticated"]},
      {"no SELECT for anon", ["REVOKE SELECT ON realtime.messages FROM anon"]},
      {"a column privilege only",
       [
         "REVOKE SELECT ON realtime.messages FROM authenticated",
         "GRANT SELECT (id) ON realtime.messages TO authenticated"
       ]}
    ]

    from_revokes =
      for {label, setup} <- revokes, role <- ["authenticated", "anon"], topic <- ["x", "y"] do
        scenario(
          "select dependent",
          "#{label}, #{role}, topic #{inspect(topic)}",
          [policy_sql("select", "FOR SELECT TO authenticated, anon USING (realtime.topic() = 'x')"), insert_policy],
          [role: role, topic: topic],
          setup: setup
        )
      end

    # A SELECT policy that fails in a way that doesn't need a row: when it is expanded, or evaluated at plan time
    select_policies = [
      {"a policy that reads the table",
       "EXISTS (SELECT 1 FROM realtime.messages m2 WHERE m2.topic = realtime.topic())"},
      {"a policy that divides by zero", "1 / 0 = 1"},
      {"a policy with a constant that raises", "('x' || '')::int = 1"},
      {"a policy that raises for this sub", "(auth.uid())::text = 'x'"},
      {"a policy that raises for this sub, and a true one", "(auth.uid())::text = 'x' OR true"},
      {"a policy that raises for this claim", "(auth.jwt() ->> 'n')::int > 0"},
      # A column against something stable that raises: the planner evaluates that when it estimates the
      # selectivity, so it may raise while planning, with the policy fully modelled
      {"a column against a stable expression that raises for this sub", "extension = (auth.uid())::text"},
      {"a column against a stable expression that raises for this sub, concatenated",
       "topic = 'user:' || (auth.uid())::text"},
      {"a column against a stable expression that raises for this claim",
       "extension = ((auth.jwt() ->> 'n')::boolean)::text"}
    ]

    from_policies =
      for {label, qual} <- select_policies, role <- ["authenticated", "anon"], sub <- [@own, "user_2abc"] do
        scenario(
          "select dependent",
          "#{label}, #{role}, sub #{inspect(sub)}",
          [policy_sql("select", "FOR SELECT TO authenticated, anon USING (#{qual})"), insert_policy],
          role: role,
          topic: "x",
          sub: sub,
          extra_claims: %{"n" => "x"}
        )
      end

    from_revokes ++ from_policies
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
        policy_sql("a_allow", "FOR SELECT TO authenticated USING (#{allow})"),
        policy_sql("b_raises", "FOR SELECT TO authenticated USING (#{raises})"),
        policy_sql("c_allow", "FOR INSERT TO authenticated WITH CHECK (#{allow})"),
        policy_sql("d_raises", "FOR INSERT TO authenticated WITH CHECK (#{raises})")
      ]
    end

    cast_raises = "(auth.jwt() ->> 'n')::int > 0"
    uid_raises = "(auth.uid())::text = 'x'"

    for {label, raises, allow, env_opts} <- [
          # `b OR true` is simplified to true before anything runs, so Postgres never evaluates what raises
          {"int cast of a claim, a policy that is constant true", cast_raises, "true", [extra_claims: %{"n" => "x"}]},
          {"uid cast, a policy that is constant true", uid_raises, "true", [sub: "user_2abc"]},
          # A policy that isn't constant is where the failing one runs first and raises
          {"int cast of a claim, a policy on the extension", cast_raises, "extension = 'broadcast'",
           [extra_claims: %{"n" => "x"}]},
          {"uid cast, a policy on the extension", uid_raises, "extension = 'broadcast'", [sub: "user_2abc"]},
          {"uid cast, a policy on the topic", uid_raises, "realtime.topic() = 'room:1'", [sub: "user_2abc"]},
          {"int cast of a claim, a policy on the topic", cast_raises, "realtime.topic() = 'room:1'",
           [extra_claims: %{"n" => "x"}]}
        ] do
      scenario("raising policies", label, raising_policies.(raises, allow), env_opts)
    end
  end
end
