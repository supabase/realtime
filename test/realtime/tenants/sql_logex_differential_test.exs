defmodule Realtime.Tenants.SqlLogexDifferentialTest do
  # The evidence for sql_logex's hypothesis: for a common user-channel policy set, the evaluator decides
  # allow/deny for every join input exactly as Postgres does, and falls back whenever it can't be sure.
  # Postgres is the oracle, every case runs through both and the answers are compared.
  #
  #   mix test test/realtime/tenants/sql_logex_differential_test.exs
  #   SQL_LOGEX_REPORT=1 mix test test/realtime/tenants/sql_logex_differential_test.exs   # coverage summary
  #
  # Level 1 compares expressions. A policy is created with the expression as a customer writes it,
  # `pg_get_expr` is read back (what the loader gives sql_logex), and the deparsed text is run in a
  # SELECT, against a row of a table, with the settings of the case. The evaluator parses and
  # evaluates the same text. Each case runs in a transaction that is rolled back.
  #
  # Level 2 compares decisions. Policy sets are created, loaded into a snapshot, and
  # `realtime.authorize` (what Realtime calls on a join) is compared with `SqlLogex.decide/3`, for
  # each extension. A call that raises is asked again for one extension at a time, to tell which raised.
  #
  # Every case ends up in one class:
  #
  #   match      the same value
  #   fallback   the evaluator said unsupported. Fine, it asks Postgres. Counted, see below
  #   mismatch   a different value, or a value where Postgres raised. Fails the test
  #   crash      the evaluator raised. Fails the test
  #
  # The decision table of the unit tests of sql_logex (policy_set_test.exs) is copied below, and what
  # it expects is checked against what Postgres does.
  use Realtime.DataCase, async: true

  alias Realtime.Database
  alias SqlLogex.Eval
  alias SqlLogex.Parser
  alias SqlLogex.Resolver
  alias SqlLogex.Snapshot

  @moduletag timeout: 600_000

  @own "c0ffee00-1111-4222-8333-444455556666"
  @other "deadbeef-0000-4000-8000-000000000001"

  # What realtime.authorize is called with by Authorization.authorize/5, for reads and writes
  @extensions ["broadcast", "presence"]

  @headers ~s({"x-client-info":"supabase-js/2.0"})

  @functions_query """
  select n.nspname, p.proname, l.lanname, p.provolatile::text, p.prosecdef, p.proconfig,
         p.prorettype::regtype::text, p.prosrc
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  join pg_language l on l.oid = p.prolang
  where p.pronargs = 0 and (n.nspname, p.proname) in (('auth', 'uid'), ('auth', 'jwt'), ('auth', 'role'), ('realtime', 'topic'))
  order by n.nspname, p.proname
  """

  @policies_query """
  select polname, polcmd::text, polpermissive,
         array(select case when r = 0 then 'public' else r::regrole::text end from unnest(polroles) r),
         pg_get_expr(polqual, polrelid), pg_get_expr(polwithcheck, polrelid)
  from pg_policy where polrelid = 'realtime.messages'::regclass order by polname
  """

  @table_query "select relrowsecurity, relforcerowsecurity from pg_class where oid = 'realtime.messages'::regclass"

  @roles_query """
  select r.rolname, r.rolbypassrls,
         has_table_privilege(r.rolname, 'realtime.messages', 'SELECT'),
         has_table_privilege(r.rolname, 'realtime.messages', 'INSERT')
  from pg_roles r where r.rolname in ('anon', 'authenticated')
  """

  # As in Realtime.Tenants.Authorization
  @authorize_query """
  SELECT read_allowed, write_allowed
  FROM realtime.authorize(
    role_name => $1,
    topic_name => $2,
    claims => $3,
    sub => $4,
    headers => $5,
    read_extensions => $6,
    write_extensions => $7
  )
  """

  @set_settings_query """
  SELECT set_config('role', $1, true),
         set_config('realtime.topic', $2, true),
         set_config('request.jwt.claims', $3, true),
         set_config('request.jwt.claim.sub', $4, true),
         set_config('request.jwt.claim.role', $5, true),
         set_config('request.headers', $6, true)
  """

  # Strings that stand for a sub, the ways Postgres's uuid_in reads them, and the ways it doesn't
  @subs [
    {"canonical", @own},
    {"upper case", String.upcase(@own)},
    {"mixed case", "C0ffEE00-1111-4222-8333-444455556666"},
    {"braced", "{" <> @own <> "}"},
    {"braced, upper case", "{" <> String.upcase(@own) <> "}"},
    {"unhyphenated", String.replace(@own, "-", "")},
    {"hyphens after every group", "c0ff-ee00-1111-4222-8333-4444-5555-6666"},
    {"braced without hyphens", "{" <> String.replace(@own, "-", "") <> "}"},
    {"all zeros", "00000000-0000-0000-0000-000000000000"},
    {"empty", ""},
    {"missing", nil},
    {"not a uuid", "user_2abc"},
    {"too short", String.slice(@own, 0..-2//1)},
    {"too long", @own <> "0"},
    {"leading space", " " <> @own},
    {"trailing space", @own <> " "},
    {"trailing newline", @own <> "\n"},
    {"non-hex digit", "g0ffee00-1111-4222-8333-444455556666"},
    {"misplaced hyphen", "c0ffee001-111-4222-8333-444455556666"},
    {"double hyphen", "c0ffee00--1111-4222-8333-444455556666"},
    {"unclosed brace", "{" <> @own},
    {"unopened brace", @own <> "}"},
    {"fullwidth digit", "０0ffee00-1111-4222-8333-444455556666"},
    {"another uuid", @other}
  ]

  @level1_groups [:three_valued, :text_and_arrays, :uid_and_role, :claims, :regex, :literals]

  # How the bodies of auth.uid()/auth.role() are called in report labels and test names
  @flavor_labels %{legacy: "legacy", supabase_auth: "supabase/auth"}

  ## The decision table of the unit tests of sql_logex (sql_logex/test/sql_logex/policy_set_test.exs,
  ## "user channels"), with what they expect. Copied, so Postgres can check the expectations.

  @uid "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11"
  @other_uid "b1ffcd00-8d1c-4ff9-cc7e-7cc0ce491b22"

  @invalid_uuid {:fallback,
                 {:unsupported, {:raises, :invalid_text_representation, "invalid input syntax for type uuid"}}}
  @regex_non_ascii {:fallback, {:unsupported, :regex_non_ascii}}

  @user_channel_reads [
    %{name: "own uid", topic: "user:#{@uid}", sub: @uid, expect: :allow},
    %{name: "someone else's uid", topic: "user:#{@other_uid}", sub: @uid, expect: :deny},
    %{name: "own uid in upper case", topic: "user:#{String.upcase(@uid)}", sub: @uid, expect: :deny},
    %{name: "the lobby topic", topic: "public:lobby", sub: @uid, expect: :allow},
    %{name: "the lobby topic in upper case", topic: "PUBLIC:LOBBY", sub: @uid, expect: :allow},
    %{name: "the lobby topic inside another one", topic: "xpublic:lobbyy", sub: @uid, expect: :allow},
    %{name: "a topic that matches nothing", topic: "room:1", sub: @uid, expect: :deny},
    %{name: "a non-ASCII topic", topic: "public:lobby:é", sub: @uid, expect: @regex_non_ascii},
    %{name: "a non-ASCII topic that can't match", topic: "café", sub: @uid, expect: @regex_non_ascii},
    %{name: "an empty topic", topic: "", sub: @uid, expect: :deny},
    %{name: "sub in upper case", topic: "user:#{@uid}", sub: String.upcase(@uid), expect: :allow},
    %{name: "braced sub", topic: "user:#{@uid}", sub: "{#{@uid}}", expect: :allow},
    %{name: "unhyphenated sub", topic: "user:#{@uid}", sub: String.replace(@uid, "-", ""), expect: :allow},
    %{
      name: "sub with hyphens after every group",
      topic: "user:#{@uid}",
      sub: "a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11",
      expect: :allow
    },
    %{name: "sub with a leading space", topic: "user:#{@uid}", sub: " #{@uid}", expect: @invalid_uuid},
    %{name: "empty sub", topic: "user:#{@uid}", sub: "", expect: :deny, supabase_auth: @invalid_uuid},
    %{name: "no sub", topic: "user:#{@uid}", sub: nil, expect: :deny},
    %{name: "no sub on the lobby topic", topic: "public:lobby", sub: nil, expect: :allow},
    %{name: "sub that isn't a uuid", topic: "user:user_2abc", sub: "user_2abc", expect: @invalid_uuid},
    %{
      name: "sub that isn't a uuid, on a topic nothing matches",
      topic: "room:1",
      sub: "user_2abc",
      expect: @invalid_uuid
    },
    %{
      name: "sub that isn't a uuid, on the lobby topic",
      topic: "public:lobby",
      sub: "user_2abc",
      expect: @invalid_uuid
    },
    %{name: "anon, own uid", topic: "user:#{@uid}", sub: @uid, role: "anon", expect: :deny},
    %{name: "anon, the lobby topic", topic: "public:lobby", sub: @uid, role: "anon", expect: :deny},
    %{
      name: "service_role",
      topic: "user:#{@uid}",
      sub: @uid,
      role: "service_role",
      expect: {:fallback, {:role, "service_role"}}
    },
    # "an extension outside the list", with the extension of the read of that test
    %{
      name: "an extension outside the list, own uid",
      topic: "user:#{@uid}",
      sub: @uid,
      extensions: ["postgres_changes"],
      expect: :deny
    },
    %{
      name: "an extension outside the list, sub that isn't a uuid",
      topic: "user:user_2abc",
      sub: "user_2abc",
      extensions: ["postgres_changes"],
      expect: @invalid_uuid
    }
  ]

  @user_channel_writes [
    %{name: "own uid", topic: "user:#{@uid}", sub: @uid, expect: :allow},
    %{name: "someone else's uid", topic: "user:#{@other_uid}", sub: @uid, expect: :deny},
    %{name: "own uid in upper case", topic: "user:#{String.upcase(@uid)}", sub: @uid, expect: :deny},
    %{name: "the lobby topic", topic: "public:lobby", sub: @uid, expect: :deny},
    %{name: "the lobby topic in upper case", topic: "PUBLIC:LOBBY", sub: @uid, expect: :deny},
    %{name: "the lobby topic inside another one", topic: "xpublic:lobbyy", sub: @uid, expect: :deny},
    %{name: "a non-ASCII topic", topic: "public:lobby:é", sub: @uid, expect: :deny},
    %{name: "an empty topic", topic: "", sub: @uid, expect: :deny},
    %{name: "sub in upper case", topic: "user:#{@uid}", sub: String.upcase(@uid), expect: :allow},
    %{name: "braced sub", topic: "user:#{@uid}", sub: "{#{@uid}}", expect: :allow},
    %{name: "unhyphenated sub", topic: "user:#{@uid}", sub: String.replace(@uid, "-", ""), expect: :allow},
    %{name: "empty sub", topic: "user:#{@uid}", sub: "", expect: :deny, supabase_auth: @invalid_uuid},
    %{name: "no sub", topic: "user:#{@uid}", sub: nil, expect: :deny},
    %{name: "sub that isn't a uuid", topic: "user:user_2abc", sub: "user_2abc", expect: @invalid_uuid},
    %{
      name: "sub that isn't a uuid, on the lobby topic",
      topic: "public:lobby",
      sub: "user_2abc",
      expect: @invalid_uuid
    },
    %{name: "anon, own uid", topic: "user:#{@uid}", sub: @uid, role: "anon", expect: :deny},
    %{
      name: "service_role",
      topic: "user:#{@uid}",
      sub: @uid,
      role: "service_role",
      expect: {:fallback, {:role, "service_role"}}
    },
    %{name: "own uid, presence", topic: "user:#{@uid}", sub: @uid, extensions: ["presence"], expect: :allow},
    %{
      name: "own uid, an extension outside the list",
      topic: "user:#{@uid}",
      sub: @uid,
      extensions: ["persistence"],
      expect: :deny
    },
    %{
      name: "sub that isn't a uuid, an extension outside the list",
      topic: "user:user_2abc",
      sub: "user_2abc",
      extensions: ["persistence"],
      expect: @invalid_uuid
    }
  ]

  setup_all do
    # Collects the results of all tests, for the report printed once the module is done
    {:ok, collector} = Agent.start(fn -> [] end)

    on_exit(fn ->
      results = Agent.get(collector, & &1)
      Agent.stop(collector)
      if System.get_env("SQL_LOGEX_REPORT") == "1", do: IO.puts(report(results))
    end)

    %{collector: collector}
  end

  setup do
    tenant = TestTenantDb.checkout_tenant(run_migrations: true)
    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
    %{db_conn: db_conn}
  end

  ## Level 1: expressions

  for group <- @level1_groups do
    test "level 1, expressions: #{group}", %{db_conn: db_conn, collector: collector} do
      functions = %{
        legacy: load_functions(db_conn, :legacy),
        supabase_auth: load_functions(db_conn, :supabase_auth)
      }

      results = Enum.map(cases(unquote(group)), &run_expression_case(db_conn, functions, unquote(group), &1))

      finish(collector, results)
    end
  end

  ## Level 2: policy sets through realtime.authorize

  for form <- [:plain, :initplan], flavor <- [:legacy, :supabase_auth] do
    test "level 2, user channels: #{form} policies, #{@flavor_labels[flavor]} auth functions", %{
      db_conn: db_conn,
      collector: collector
    } do
      scenarios = user_channel_grid(unquote(form), unquote(flavor))
      finish(collector, Enum.flat_map(scenarios, &run_scenario(db_conn, &1)))
    end
  end

  test "level 2, user channels: the decision table of the unit tests", %{db_conn: db_conn, collector: collector} do
    finish(collector, Enum.flat_map(user_channel_table_scenarios(), &run_scenario(db_conn, &1)))
  end

  test "level 2, generator policies", %{db_conn: db_conn, collector: collector} do
    finish(collector, Enum.flat_map(generator_scenarios(), &run_scenario(db_conn, &1)))
  end

  test "level 2, combining policies", %{db_conn: db_conn, collector: collector} do
    finish(collector, Enum.flat_map(combination_scenarios(), &run_scenario(db_conn, &1)))
  end

  test "level 2, what the snapshot has to rule out", %{db_conn: db_conn, collector: collector} do
    finish(collector, Enum.flat_map(snapshot_scenarios(), &run_scenario(db_conn, &1)))
  end

  # See select_dependent_scenarios/0
  test "level 2, writes that fail with the SELECT of realtime.authorize", %{db_conn: db_conn, collector: collector} do
    finish(collector, Enum.flat_map(select_dependent_scenarios(), &run_scenario(db_conn, &1)))
  end

  test "level 2, a policy that raises next to one that allows", %{db_conn: db_conn, collector: collector} do
    finish(collector, Enum.flat_map(raising_policy_scenarios(), &run_scenario(db_conn, &1)))
  end

  # Records the results for the report, and fails with every case that isn't as it has to be
  defp finish(collector, results) do
    Agent.update(collector, &(results ++ &1))

    case Enum.filter(results, &failure?/1) do
      [] ->
        :ok

      failures ->
        by_class = failures |> Enum.frequencies_by(& &1.class) |> Enum.map_join(", ", fn {c, n} -> "#{n} #{c}" end)

        flunk("""
        #{length(failures)} of #{length(results)} cases are not as they have to be (#{by_class}).

        #{Enum.map_join(failures, "\n", &format_failure/1)}
        """)
    end
  end

  # What a case has to show. The evaluator may match or fall back, never differ and never crash. And what
  # the unit tests of sql_logex expect of a decision has to be consistent with Postgres.
  defp failure?(result), do: result.class in [:mismatch, :crash] or table_verdict(result) == :disagrees

  defp format_failure(result) do
    table =
      if table_verdict(result) == :disagrees,
        do: "\n  the unit tests of sql_logex expect #{inspect(result.table)}, which disagrees with Postgres",
        else: ""

    """
    [#{result.group}] #{result.name}
      #{result.class}#{if result.sub, do: " (#{result.sub})"}#{table}
      postgres:  #{format_postgres(result.pg)}
      evaluator: #{format_evaluator(result.ex)}
    #{result.detail}
    """
  end

  defp format_postgres({:ok, value}), do: "returned #{inspect(value)}"
  defp format_postgres({:error, code, name, message}), do: "raised #{code} #{name}: #{message}"

  defp format_evaluator({:value, value}), do: inspect(value)

  defp format_evaluator({:unsupported, reason}), do: "unsupported #{inspect(reason, limit: 12, printable_limit: 200)}"
  defp format_evaluator({:crash, reason}), do: "crashed #{inspect(reason, limit: 12, printable_limit: 400)}"

  ## Classifying

  # pg is {:ok, value} | {:error, sqlstate, code, message}
  # ex is {:value, value} | {:unsupported, reason} | {:crash, reason}
  defp classify(_pg, {:crash, _reason}), do: {:crash, nil}
  defp classify({:ok, value}, {:value, value}), do: {:match, nil}
  defp classify({:ok, _value}, {:value, _other}), do: {:mismatch, :postgres_value}
  defp classify({:ok, _value}, {:unsupported, _reason}), do: {:fallback, :postgres_value}
  defp classify({:error, _sqlstate, _code, _message}, {:value, _value}), do: {:mismatch, :postgres_error}

  # Postgres raised, and the evaluator fell back: because it saw the error coming, because it saw another
  # one coming, or for another reason. Only reported
  defp classify({:error, _sqlstate, code, _message}, {:unsupported, reason}) do
    case raises_state(reason) do
      nil -> {:fallback, :postgres_error}
      ^code -> {:fallback, :postgres_error_predicted}
      _other -> {:fallback, :postgres_error_other_sqlstate}
    end
  end

  defp raises_state({:raises, state, _detail}), do: state
  defp raises_state(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> Enum.find_value(&raises_state/1)
  defp raises_state(list) when is_list(list), do: Enum.find_value(list, &raises_state/1)
  defp raises_state(_other), do: nil

  # `ex` is the answer of the evaluator
  defp result(level, group, name, pg, ex, detail, extra) do
    {class, sub} = classify(pg, ex)

    Map.merge(
      %{
        level: level,
        group: group,
        name: name,
        class: class,
        sub: sub,
        pg: pg,
        ex: ex,
        detail: detail,
        table: nil,
        scenario: nil,
        role: nil,
        meta: %{},
        operation: nil,
        extension: nil,
        user_channels: nil
      },
      extra
    )
  end

  ## Loading from Postgres, as the loader will do in Realtime

  # The deparsed text qualifies functions and operators by the session's search_path, so it is
  # pinned to nothing while reading what sql_logex gets, and put back after
  defp with_empty_search_path(conn, fun) do
    %{rows: [[search_path]]} = Postgrex.query!(conn, "SELECT current_setting('search_path')", [])
    Postgrex.query!(conn, "SET LOCAL search_path = ''", [])
    value = fun.()
    Postgrex.query!(conn, "SELECT set_config('search_path', $1, true)", [search_path])
    value
  end

  defp load_functions_in_transaction(conn) do
    with_empty_search_path(conn, fn ->
      %{rows: functions} = Postgrex.query!(conn, @functions_query, [])

      for [schema, name, language, volatility, security_definer, config, return_type, source] <- functions do
        %{
          schema: schema,
          name: name,
          language: language,
          volatility: volatility,
          security_definer: security_definer,
          config: config,
          return_type: return_type,
          source: source
        }
      end
    end)
  end

  defp load_snapshot_input(conn) do
    with_empty_search_path(conn, fn ->
      %{rows: [[rls_enabled, rls_forced]]} = Postgrex.query!(conn, @table_query, [])
      %{rows: roles} = Postgrex.query!(conn, @roles_query, [])
      %{rows: policies} = Postgrex.query!(conn, @policies_query, [])

      %{
        rls_enabled: rls_enabled,
        rls_forced: rls_forced,
        roles:
          Map.new(roles, fn [name, bypass_rls, select, insert] ->
            {name, %{bypass_rls: bypass_rls, select: select, insert: insert}}
          end),
        policies:
          for [name, cmd, permissive, roles, qual, with_check] <- policies do
            %{name: name, cmd: cmd, permissive: permissive, roles: roles, qual: qual, with_check: with_check}
          end,
        functions: load_functions_in_transaction(conn)
      }
    end)
  end

  # The functions of the database the cases run against. The legacy bodies are the ones of the
  # supabase/postgres image, supabase/auth's are what production projects run.
  defp load_functions(db_conn, flavor) do
    {:error, functions} =
      Postgrex.transaction(db_conn, fn conn ->
        prepare_functions!(conn, flavor)
        Postgrex.rollback(conn, load_functions_in_transaction(conn))
      end)

    functions
  end

  defp prepare_functions!(conn, :legacy), do: Postgrex.query!(conn, SqlLogexPolicies.auth_jwt_statement(), [])

  defp prepare_functions!(conn, :supabase_auth) do
    prepare_functions!(conn, :legacy)
    Postgrex.query!(conn, SqlLogexPolicies.supabase_auth_functions_statement(), [])
  end

  defp run!(conn, statement, name) do
    case Postgrex.query(conn, statement, []) do
      {:ok, _result} -> :ok
      {:error, error} -> raise "#{inspect(name)}: #{Exception.message(error)}\nwhile running:\n#{statement}"
    end
  end

  defp postgres_error(%Postgrex.Error{postgres: %{pg_code: sqlstate, code: code, message: message}}),
    do: {:error, sqlstate, code, message}

  ## The environment of a case: what realtime.authorize sets, and the row

  # sub, topic and extension are as in a join, nil is NULL. `claims` is the JSON text, built from the
  # role and sub unless given (as text, or as a map to encode). `extra_claims` are added to the
  # built ones. The row has the topic and extension, unless given.
  defp env(opts) do
    role = Keyword.get(opts, :role, "authenticated")
    topic = Keyword.get(opts, :topic, "room:1")
    sub = Keyword.get(opts, :sub, @own)

    claims =
      case Keyword.fetch(opts, :claims) do
        {:ok, claims} when is_map(claims) ->
          Jason.encode!(claims)

        {:ok, claims} ->
          claims

        :error ->
          %{"role" => role}
          |> then(&if sub, do: Map.put(&1, "sub", sub), else: &1)
          |> Map.merge(Keyword.get(opts, :extra_claims, %{}))
          |> Jason.encode!()
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

  defp logex_env(env, extension) do
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

  defp describe_env(env, extension) do
    """
        role=#{inspect(env.role)} topic=#{inspect(env.topic)} row=#{inspect({env.row_topic, extension})}
        sub=#{inspect(env.sub)} claim_role=#{inspect(env.claim_role)}
        claims=#{inspect(env.claims)}\
    """
  end

  ## Level 1 runner

  defp run_expression_case(db_conn, functions, group, kase) do
    {:error, {deparsed, pg}} =
      Postgrex.transaction(db_conn, fn conn ->
        prepare_functions!(conn, kase.functions)
        Postgrex.query!(conn, "SET LOCAL search_path = ''", [])
        deparsed = create_policy_and_read_back!(conn, kase)
        Postgrex.rollback(conn, {deparsed, postgres_value(conn, deparsed, kase.env)})
      end)

    ex = evaluate(deparsed, kase.env, functions[kase.functions])

    detail = """
      sql:       #{kase.sql}
      deparsed:  #{deparsed}
      functions: #{kase.functions}
      env:
    #{describe_env(kase.env, kase.env.extension)}
    """

    result(1, group, kase.name, pg, ex, detail, %{})
  end

  defp create_policy_and_read_back!(conn, kase) do
    run!(conn, "CREATE POLICY tmp ON realtime.messages FOR SELECT TO authenticated USING (#{kase.sql})", kase.name)

    %{rows: [[deparsed]]} =
      Postgrex.query!(
        conn,
        "SELECT pg_get_expr(polqual, polrelid) FROM pg_policy WHERE polrelid = 'realtime.messages'::regclass AND polname = 'tmp'",
        []
      )

    deparsed
  end

  # What Postgres evaluates the deparsed text to, with the settings and the row of the case
  defp postgres_value(conn, deparsed, env) do
    # The row is in a table. As a VALUES list with parameters it would be a constant for the planner,
    # which folds what a constant allows: NULLIF(NULL, <raises>) is NULL there, and raises on a column.
    # The policy of a join is evaluated against a column of realtime.messages
    Postgrex.query!(conn, "CREATE TEMP TABLE m AS SELECT $1::text AS topic, $2::text AS extension", [
      env.row_topic,
      env.extension
    ])

    Postgrex.query!(conn, "GRANT SELECT ON m TO PUBLIC", [])
    Postgrex.query!(conn, @set_settings_query, [env.role, env.topic, env.claims, env.sub, env.claim_role, env.headers])

    case Postgrex.query(conn, "SELECT #{deparsed} FROM pg_temp.m", []) do
      {:ok, %Postgrex.Result{rows: [[value]]}} -> {:ok, value}
      {:error, %Postgrex.Error{} = error} -> postgres_error(error)
    end
  end

  defp evaluate(deparsed, env, functions) do
    {ir, _type} = deparsed |> Parser.parse() |> Resolver.resolve(functions)

    case Eval.eval(ir, logex_env(env, env.extension)) do
      {:unsupported, reason} -> {:unsupported, reason}
      value -> {:value, value}
    end
  rescue
    exception -> {:crash, Exception.format(:error, exception, __STACKTRACE__)}
  end

  ## Level 2 runner

  # name, group and the options of a scenario of Level 2:
  #   policies:   CREATE POLICY statements, run after the ones that are on the table are dropped
  #   setup:      statements run before them
  #   env:        see env/1
  #   functions:  :legacy | :supabase_auth, see load_functions/2
  #   extensions: what is asked for, both as read and write extensions
  #   table:      %{{:read | :write, extension} => decision} the unit tests of sql_logex expect
  #   user_channels: :grid | :table | :planner, for the user-channel coverage
  defp scenario(group, name, policies, env_opts, opts \\ []) do
    %{
      group: group,
      name: name,
      policies: policies,
      setup: Keyword.get(opts, :setup, []),
      env: env(env_opts),
      functions: Keyword.get(opts, :functions, :legacy),
      extensions: Keyword.get(opts, :extensions, @extensions),
      table: Keyword.get(opts, :table, %{}),
      user_channels: Keyword.get(opts, :user_channels),
      meta: Keyword.get(opts, :meta, %{})
    }
  end

  defp run_scenario(db_conn, scenario) do
    {:error, {snapshot_input, pg}} =
      Postgrex.transaction(db_conn, fn conn ->
        prepare_functions!(conn, scenario.functions)
        Enum.each(scenario.setup, &run!(conn, &1, scenario.name))
        drop_policies!(conn, scenario.name)
        Enum.each(scenario.policies, &run!(conn, &1, scenario.name))
        snapshot_input = load_snapshot_input(conn)
        Postgrex.rollback(conn, {snapshot_input, authorize_outcomes(conn, scenario.env, scenario.extensions)})
      end)

    snapshot = build_snapshot(snapshot_input)

    for operation <- [:read, :write], extension <- scenario.extensions do
      key = {operation, extension}
      pg_outcome = Map.fetch!(pg, key)
      logex_env = logex_env(scenario.env, extension)
      ex = decide(snapshot, logex_env, operation)

      detail = """
        operation: #{operation}, extension: #{extension}, functions: #{scenario.functions}
        policies:
      #{Enum.map_join(scenario.policies, "\n", &("    " <> String.replace(&1, "\n", " ")))}
        env:
      #{describe_env(scenario.env, extension)}
      """

      result(2, scenario.group, "#{scenario.name} [#{operation} #{extension}]", pg_outcome, ex, detail, %{
        user_channels: scenario.user_channels,
        scenario: scenario.name,
        role: scenario.env.role,
        meta: scenario.meta,
        operation: operation,
        extension: extension,
        table: Map.get(scenario.table, key)
      })
    end
  end

  defp drop_policies!(conn, name) do
    %{rows: policies} =
      Postgrex.query!(conn, "SELECT polname FROM pg_policy WHERE polrelid = 'realtime.messages'::regclass", [])

    for [policy] <- policies do
      run!(conn, ~s(DROP POLICY "#{policy}" ON realtime.messages), name)
    end
  end

  # What realtime.authorize returns for each {operation, extension}. A policy that raises fails the
  # whole call, so when that happens each is asked for on its own to tell which one raised.
  defp authorize_outcomes(conn, env, extensions) do
    case authorize(conn, env, extensions, extensions) do
      {:ok, [read_allowed, write_allowed]} ->
        outcomes(:read, extensions, read_allowed) |> Map.merge(outcomes(:write, extensions, write_allowed))

      {:error, _error} ->
        for operation <- [:read, :write], extension <- extensions, into: %{} do
          {read, write} = if operation == :read, do: {[extension], []}, else: {[], [extension]}

          case authorize(conn, env, read, write) do
            {:ok, [[allowed], []]} when operation == :read -> {{operation, extension}, {:ok, allowed}}
            {:ok, [[], [allowed]]} when operation == :write -> {{operation, extension}, {:ok, allowed}}
            {:error, error} -> {{operation, extension}, error}
          end
        end
    end
  end

  defp outcomes(operation, extensions, allowed) do
    extensions |> Enum.zip(allowed) |> Map.new(fn {extension, value} -> {{operation, extension}, {:ok, value}} end)
  end

  defp authorize(conn, env, read_extensions, write_extensions) do
    params = [env.role, env.topic, env.claims, env.sub, env.headers, read_extensions, write_extensions]

    # In a savepoint, so that a call that raises doesn't abort the transaction
    case Postgrex.query(conn, @authorize_query, params, mode: :savepoint) do
      {:ok, %Postgrex.Result{rows: [[read_allowed, write_allowed]]}} -> {:ok, [read_allowed, write_allowed]}
      {:error, %Postgrex.Error{} = error} -> {:error, postgres_error(error)}
    end
  end

  defp build_snapshot(input), do: Snapshot.new(input)

  defp decide(snapshot, env, operation) do
    case SqlLogex.decide(snapshot, env, operation) do
      decision when decision in [:allow, :deny] ->
        {:value, decision == :allow}

      {:fallback, {:exception, _message} = reason} ->
        {:crash, reason}

      {:fallback, reason} ->
        {:unsupported, reason}
    end
  rescue
    exception -> {:crash, Exception.format(:error, exception, __STACKTRACE__)}
  end

  ## Level 1 cases

  # An expression as a customer writes it, the environment it is run in, and the auth functions the
  # database has
  defp expression_case(sql, env_opts \\ [], opts \\ []) do
    functions = Keyword.get(opts, :functions, :legacy)
    env_summary = if env_opts == [], do: "", else: " with #{inspect(env_opts, limit: 8, printable_limit: 60)}"
    functions_summary = if functions == :legacy, do: "", else: " (#{functions} functions)"

    %{
      name: sql <> env_summary <> functions_summary,
      sql: sql,
      env: env(env_opts),
      functions: functions
    }
  end

  defp lit(string), do: "'" <> String.replace(string, "'", "''") <> "'"

  defp cases(:three_valued) do
    constants =
      for(a <- ~w(true false NULL), b <- ~w(true false NULL), op <- ~w(AND OR), do: expression_case("#{a} #{op} #{b}")) ++
        for(a <- ~w(true false NULL), do: expression_case("NOT #{a}"))

    # A is true, false or NULL by the topic, B by the extension
    expressions = [
      "realtime.topic() = 'a' AND extension = 'x'",
      "realtime.topic() = 'a' OR extension = 'x'",
      "NOT (realtime.topic() = 'a')",
      "NOT (realtime.topic() = 'a' AND extension = 'x')",
      "NOT (realtime.topic() = 'a' OR extension = 'x')",
      "NOT (realtime.topic() = 'a') OR extension = 'x'",
      "NOT (realtime.topic() = 'a') AND NOT (extension = 'x')",
      "realtime.topic() = 'a' AND (extension = 'x' OR NOT (realtime.topic() = 'a'))",
      "(realtime.topic() = 'a' OR extension = 'x') AND realtime.topic() <> 'b'",
      "realtime.topic() = 'a' AND extension = 'x' AND realtime.topic() <> 'b'",
      "realtime.topic() = 'a' OR extension = 'x' OR realtime.topic() = 'b'",
      "(realtime.topic() = 'a') IS NULL",
      "(realtime.topic() = 'a' AND extension = 'x') IS NOT NULL",
      "NOT (extension IS NULL) AND realtime.topic() IS NOT NULL",
      # Where one side is something we don't evaluate, and the other may decide
      "realtime.topic() = 'a' OR lower(extension) = 'x'",
      "realtime.topic() = 'a' AND lower(extension) = 'x'",
      "lower(extension) = 'x' OR realtime.topic() = 'a'",
      "lower(extension) = 'x' AND realtime.topic() = 'a'",
      "NOT (lower(extension) = 'x')",
      "NOT (lower(extension) = 'x' AND realtime.topic() = 'a')"
    ]

    sources =
      for expression <- expressions, topic <- ["a", "b", nil], extension <- ["x", "y", nil] do
        expression_case(expression, topic: topic, extension: extension)
      end

    constants ++ sources
  end

  defp cases(:text_and_arrays) do
    concat =
      for sql <- [
            "realtime.topic() = 'x' || NULL",
            "realtime.topic() = 'a' || NULL",
            "('x' || realtime.topic()) = 'xa'",
            "('x' || realtime.topic()) IS NULL",
            "realtime.topic() || extension = 'ab'",
            "(realtime.topic() || extension) IS NULL",
            "coalesce(realtime.topic() || extension, 'none') = 'none'",
            "'a' || 'b' = 'ab'",
            "realtime.topic() = 'a' || 'b'",
            "extension || '' = ''",
            "'' || extension = extension",
            "'x' || NULL IS NULL",
            "NOT ('x' || NULL IS NULL)",
            "realtime.topic() <> 'x' || extension"
          ],
          topic <- ["a", "ab", "", nil],
          extension <- ["b", nil] do
        expression_case(sql, topic: topic, extension: extension)
      end

    equality =
      for sql <- [
            "realtime.topic() = 'x'",
            "realtime.topic() <> 'x'",
            "extension = 'x'",
            "realtime.topic() = extension",
            "'x' = realtime.topic()",
            "realtime.topic() IN ('x')",
            "realtime.topic() NOT IN ('x')",
            "realtime.topic() = ''",
            "realtime.topic() <> ''"
          ],
          topic <- [
            "x",
            "X",
            "x ",
            " x",
            "",
            nil,
            "é",
            "é",
            " ",
            "x\ny",
            "it's",
            "a\\b",
            "日本",
            "😀",
            "x\t"
          ] do
        expression_case(sql, topic: topic, extension: "x")
      end

    # Also against the NFC and NFD spelling of é
    unicode =
      for topic <- ["é", "é"], literal <- ["é", "é"] do
        expression_case("realtime.topic() = #{lit(literal)}", topic: topic)
      end

    any =
      for sql <- [
            "extension IN ('a', 'b')",
            "extension IN ('a', NULL)",
            "extension IN ('a', 'b', NULL)",
            "extension NOT IN ('a', 'b')",
            "extension NOT IN ('a', NULL)",
            "extension IN ('a')",
            "extension NOT IN ('a')",
            "NOT (extension IN ('a', 'b'))",
            "NOT (extension NOT IN ('a', 'b'))",
            "extension = ANY ('{}'::text[])",
            "extension = ANY (ARRAY[]::text[])",
            "extension <> ALL ('{}'::text[])",
            "extension <> ALL (ARRAY[]::text[])",
            "extension = ANY (ARRAY['a', 'b'])",
            "extension = ANY (ARRAY['a', NULL])",
            "extension <> ALL (ARRAY['a', NULL])",
            "extension = ANY ('{a,b}'::text[])",
            "extension = ANY ('{a,NULL}'::text[])",
            "extension = ANY (ARRAY[realtime.topic(), 'z'])",
            "realtime.topic() IN (extension, 'z')",
            "realtime.topic() NOT IN (extension, 'z')",
            "extension IN ('a', 'b') AND extension NOT IN ('b')",
            "(extension IN ('a', NULL)) IS NULL",
            "NOT (extension = ANY ('{}'::text[]))"
          ],
          extension <- ["a", "b", "c", nil],
          topic <- ["a", "z", nil] do
        expression_case(sql, topic: topic, extension: extension)
      end

    null_tests =
      for sql <- [
            "extension IS NULL",
            "extension IS NOT NULL",
            "realtime.topic() IS NULL",
            "realtime.topic() IS NOT NULL",
            "NOT (realtime.topic() IS NULL)",
            "(extension = 'a') IS NULL",
            "(extension = 'a') IS NOT NULL",
            "realtime.topic() IS NULL OR extension IS NULL",
            "realtime.topic() IS NOT NULL AND extension IS NOT NULL"
          ],
          topic <- ["a", "", nil],
          extension <- ["a", nil] do
        expression_case(sql, topic: topic, extension: extension)
      end

    coalesce_and_nullif =
      for sql <- [
            "coalesce(realtime.topic(), 'x') = 'x'",
            "coalesce(realtime.topic(), extension, 'z') = 'z'",
            "coalesce(NULL::text, extension) = 'a'",
            "coalesce(extension = 'a', false)",
            "coalesce(extension = 'a', true)",
            "coalesce(extension = 'a', realtime.topic() = 'a')",
            "coalesce(NULL::boolean, NULL::boolean) IS NULL",
            "nullif(realtime.topic(), 'x') = 'y'",
            "nullif(realtime.topic(), 'x') IS NULL",
            "nullif(extension, realtime.topic()) IS NULL",
            "nullif(extension, realtime.topic()) = extension",
            "coalesce(nullif(extension, ''), 'd') = 'd'",
            "nullif(extension, NULL) = 'a'",
            "nullif(NULL::text, 'a') IS NULL",
            "coalesce(nullif(realtime.topic(), 'a'), 'fallback') = 'fallback'"
          ],
          topic <- ["x", "a", "", nil],
          extension <- ["a", "", nil] do
        expression_case(sql, topic: topic, extension: extension)
      end

    # COALESCE only evaluates what it needs. When the sub isn't a uuid, the cast is only reached if the
    # extension is NULL. The evaluator falls back on the cast either way
    lazy =
      for sql <- [
            "coalesce(extension, (auth.uid())::text) = 'a'",
            "coalesce(extension = 'a', (auth.uid())::text = 'x')",
            "nullif(extension, (auth.uid())::text) IS NULL"
          ],
          extension <- ["a", "b", nil] do
        expression_case(sql, sub: "user_2abc", extension: extension)
      end

    # Postgres 17 raises 22012 division_by_zero here: the planner folds the constant argument before
    # COALESCE would stop at the first one, so the evaluator has to fall back
    folded_constant = [expression_case("coalesce(realtime.topic(), (1 / 0)::text) = 'x'", topic: "x")]

    # Constructs the evaluator doesn't model. They have to fall back, and Postgres has the answer
    unsupported =
      for sql <- [
            "length(realtime.topic()) > 3",
            "lower(extension) = 'broadcast'",
            "realtime.topic() LIKE 'user:%'",
            "realtime.topic() ILIKE 'USER:%'",
            "realtime.topic() ~~ 'user:%'",
            "starts_with(realtime.topic(), 'user:')",
            "split_part(realtime.topic(), ':', 1) = 'user'",
            "realtime.topic() = ANY (string_to_array('a,b', ','))",
            "CASE WHEN extension = 'broadcast' THEN true ELSE false END",
            "CASE extension WHEN 'broadcast' THEN true WHEN 'presence' THEN NULL ELSE false END",
            "EXISTS (SELECT 1 FROM realtime.messages m2 WHERE m2.topic = realtime.topic())",
            "(select count(*) from realtime.messages) = 0",
            "extension IS DISTINCT FROM 'broadcast'",
            "extension IS NOT DISTINCT FROM NULL",
            "(extension = 'broadcast') IS TRUE",
            "(extension = 'broadcast') IS NOT TRUE",
            "(extension = 'broadcast') IS FALSE",
            "(extension = 'broadcast') IS UNKNOWN",
            "extension BETWEEN 'a' AND 'c'",
            "extension > 'a'",
            "auth.email() = 'a@b.c'",
            "current_setting('request.jwt.claim.email', true) = 'a'",
            "current_setting('app.settings.foo', true) IS NULL",
            "current_setting('request.jwt.claims') IS NOT NULL",
            "current_setting('request.jwt.claim', true) IS NULL",
            "now() > '2000-01-01'::timestamptz"
          ],
          topic <- ["user:abc", ""] do
        expression_case(sql, topic: topic)
      end

    concat ++ equality ++ unicode ++ any ++ null_tests ++ coalesce_and_nullif ++ lazy ++ folded_constant ++ unsupported
  end

  defp cases(:uid_and_role) do
    templates = [
      "(auth.uid())::text = '#{@own}'",
      "auth.uid() = '#{@own}'::uuid",
      "auth.uid() IS NULL",
      "realtime.topic() = 'user:' || auth.uid()",
      "(select auth.uid()) <> '#{@other}'::uuid",
      "coalesce(auth.uid() = '#{@own}'::uuid, false)"
    ]

    uid =
      for flavor <- [:legacy, :supabase_auth], {_label, sub} <- @subs, sql <- templates do
        expression_case(sql, [sub: sub, topic: "user:#{@own}"], functions: flavor)
      end

    # Where supabase/auth's body falls back to the claims: sub is NULL, '' or set, and the claims disagree
    claims_fallback =
      for flavor <- [:legacy, :supabase_auth],
          sql <- ["auth.uid() = '#{@own}'::uuid", "auth.uid() IS NULL"],
          opts <- [
            [sub: nil, claims: ~s({"sub":"#{@own}"})],
            [sub: "", claims: ~s({"sub":"#{@own}"})],
            [sub: "", claims: ~s({"sub":""})],
            [sub: nil, claims: ~s({"sub":null})],
            [sub: nil, claims: ~s({"sub":5})],
            [sub: nil, claims: ~s({"sub":"user_2abc"})],
            [sub: nil, claims: ~s({"sub":"#{@own}","sub":"#{@other}"})],
            [sub: nil, claims: ~s({"x":{"sub":"#{@own}"}})],
            [sub: nil, claims: "{}"],
            [sub: nil, claims: "[]"],
            [sub: nil, claims: ""],
            [sub: nil, claims: nil],
            [sub: nil, claims: "not json"],
            [sub: nil, claims: ~s({"sub":"#{@own}","x":"\\u0000"})],
            [sub: @own, claims: ~s({"sub":"#{@other}"})],
            [sub: @own, claims: "not json"],
            [sub: @own, claims: ~s({"x":"\\u0000"})],
            [sub: @own, claims: nil]
          ] do
        expression_case(sql, opts, functions: flavor)
      end

    role =
      for flavor <- [:legacy, :supabase_auth],
          role <- ["authenticated", "anon", "service_role"],
          sql <- [
            "auth.role() = 'authenticated'",
            "(select auth.role()) = 'anon'",
            "auth.role() IS NULL",
            "auth.role() <> 'service_role'"
          ] do
        expression_case(sql, [role: role], functions: flavor)
      end

    role_claims_fallback =
      for flavor <- [:legacy, :supabase_auth],
          sql <- ["auth.role() = 'authenticated'", "auth.role() IS NULL"],
          opts <- [
            [claim_role: nil],
            [claim_role: ""],
            [claim_role: "anon"],
            [claim_role: nil, claims: ~s({"role":"anon"})],
            [claim_role: "", claims: ~s({"role":null})],
            [claim_role: nil, claims: ~s({"role":"authenticated","role":"anon"})],
            [claim_role: nil, claims: "not json"],
            [claim_role: "anon", claims: "not json"]
          ] do
        expression_case(sql, opts, functions: flavor)
      end

    uid ++ claims_fallback ++ role ++ role_claims_fallback
  end

  defp cases(:claims) do
    # Values of a claim as Jason encodes them
    values = [
      "v",
      "V",
      "",
      " v",
      "v ",
      "héllo",
      "日本語",
      "😀",
      "quote \"",
      "backslash \\",
      "newline \n",
      "tab \t",
      "slash /",
      "control \u0001",
      "del \u007f",
      "a" <> <<0>> <> "b",
      <<0>>,
      true,
      false,
      nil,
      0,
      1,
      -1,
      1.5,
      100.0,
      1.0e-7,
      12_345_678_901_234_567_890,
      %{"a" => 1},
      %{},
      [1, 2],
      [],
      "true",
      "1e2"
    ]

    from_jason =
      for value <- values,
          sql <- [
            "auth.jwt() ->> 'x' = #{lit(String.replace(claim_text(value), <<0>>, ""))}",
            "auth.jwt() ->> 'x' = 'v'",
            "auth.jwt() ->> 'x' IS NULL",
            "current_setting('request.jwt.claims', true)::jsonb ->> 'x' = #{lit(String.replace(claim_text(value), <<0>>, ""))}",
            "(select auth.jwt() ->> 'x') = 'v'",
            "(auth.jwt() ->> 'x')::boolean",
            "coalesce((auth.jwt() ->> 'x')::boolean, false)"
          ] do
        expression_case(sql, extra_claims: %{"x" => value})
      end

    # Claims written by hand, as JSON text
    raw = [
      {"duplicate keys, last wins", ~s({"x":"first","x":"last"})},
      {"duplicate keys, last is null", ~s({"x":"first","x":null})},
      {"duplicate keys, last is an object", ~s({"x":"first","x":{"a":1}})},
      {"duplicate keys of different case", ~s({"X":"1","x":"2"})},
      {"only nested", ~s({"y":{"x":"deep"}})},
      {"escaped unicode", ~s({"x":"caf\\u00e9"})},
      {"surrogate pair", ~s({"x":"\\ud83d\\ude00"})},
      {"lone high surrogate", ~s({"x":"\\ud83d"})},
      {"lone low surrogate", ~s({"x":"\\ude00"})},
      {"NUL escape", ~s({"x":"\\u0000"})},
      {"NUL escape in another value", ~s({"y":"\\u0000","x":"v"})},
      {"NUL escape in a key", ~s({"\\u0000":1,"x":"v"})},
      {"NUL escape in a key that is overwritten", ~s({"\\u0000":1,"x":"v","\\u0000":2})},
      {"slash escape", ~s({"x":"a\\/b"})},
      {"all simple escapes", ~s({"x":"\\b\\f\\n\\r\\t\\"\\\\"})},
      {"whitespace around everything", ~s( \n{ "x" : "v" }\t )},
      {"number 1e2", ~s({"x":1e2})},
      {"number 1E+2", ~s({"x":1E+2})},
      {"number 0.10", ~s({"x":0.10})},
      {"number -0", ~s({"x":-0})},
      {"number 1.50", ~s({"x":1.50})},
      {"number 1e-7", ~s({"x":1e-7})},
      {"a huge number", ~s({"x":100000000000000000000})},
      {"a nested object", ~s({"x":{"b":[1,{"c":null}],"a":"é"}})},
      {"true", ~s({"x":true})},
      {"top-level array", ~s(["x"])},
      {"top-level array of objects", ~s([{"x":"v"}])},
      {"top-level string", ~s("x")},
      {"top-level number", "5"},
      {"top-level null", "null"},
      {"top-level true", "true"},
      {"empty object", "{}"},
      {"empty text", ""},
      {"NULL", nil},
      {"a space", " "},
      {"a newline", "\n"},
      {"trailing comma", ~s({"x":"v",})},
      {"single quotes", "{'x':'v'}"},
      {"trailing garbage", ~s({"x":"v"} x)},
      {"unterminated", ~s({"x":"v")},
      {"truncated escape", ~s({"x":"\\u12"})},
      {"a raw tab in a string", ~s({"x":"a\tb"})},
      {"a raw newline in a string", ~s({"x":"a\nb"})},
      {"a BOM", "﻿" <> ~s({"x":"v"})},
      {"a key with unicode", ~s({"é":"v","x":"y"})},
      {"deeply nested", String.duplicate("[", 50) <> String.duplicate("]", 50)},
      {"not json", "not json"}
    ]

    from_raw =
      for {_label, json} <- raw,
          sql <- [
            "auth.jwt() ->> 'x' = 'v'",
            "auth.jwt() ->> 'x' IS NULL",
            "current_setting('request.jwt.claims', true)::jsonb ->> 'x' IS NULL",
            "auth.jwt() ->> 'é' = 'v'",
            "auth.jwt() ->> '' IS NULL"
          ] do
        expression_case(sql, claims: json)
      end

    # The usual ways to look at the token
    usual =
      for role <- ["authenticated", "anon", "service_role"],
          sql <- [
            "auth.jwt() ->> 'role' = 'authenticated'",
            "(select auth.jwt() ->> 'role') = 'authenticated'",
            "auth.jwt() ->> 'sub' = '#{@own}'",
            "(auth.jwt() ->> 'sub')::uuid = '#{@own}'::uuid",
            "(auth.jwt() -> 'app_metadata') ->> 'role' = 'admin'",
            "(auth.jwt() -> 'app_metadata' ->> 'role') = 'admin'",
            "auth.jwt() ->> 'email' = 'a@b.c'",
            "coalesce(auth.jwt() ->> 'email', '') = ''",
            "auth.jwt() ->> 'aal' = 'aal2'",
            "(auth.jwt() ->> 'exp')::bigint > 0",
            "(auth.jwt() ->> 'x')::int > 0",
            "(auth.jwt() ->> 'x')::numeric > 0",
            "auth.jwt() ? 'x'",
            "auth.jwt() @> '{\"x\":\"v\"}'::jsonb",
            "auth.jwt() -> 'x' = '\"v\"'::jsonb"
          ],
          claims <- [
            %{"role" => role, "sub" => @own},
            %{
              "role" => role,
              "sub" => @own,
              "email" => "a@b.c",
              "aal" => "aal2",
              "exp" => 1_900_000_000,
              "x" => "5",
              "app_metadata" => %{"role" => "admin"}
            },
            %{"role" => role, "sub" => @own, "x" => "abc", "app_metadata" => %{}}
          ] do
        expression_case(sql, role: role, claims: claims)
      end

    # What ::boolean accepts, from boolean.sql
    booleans =
      for text <-
            ~w(true TRUE True tRuE t T yes YES y Y on ON 1 false FALSE f F no n N off OFF of 0 maybe tru truee yess o on_ off_ 11 000 ye ya nope 2 -1) ++
              [
                "",
                "  ",
                " t ",
                " on ",
                "\ttrue",
                "true\n",
                "\n true \r",
                "\v t",
                "\ft\f",
                " true",
                "true ",
                "ｔｒｕｅ",
                "٣",
                "tr",
                "1 ",
                " 0",
                "t rue"
              ],
          sql <- [
            "(current_setting('request.jwt.claims', true)::jsonb ->> 'k')::boolean",
            "coalesce((auth.jwt() ->> 'k')::boolean, false)",
            "NOT (auth.jwt() ->> 'k')::boolean"
          ] do
        expression_case(sql, extra_claims: %{"k" => text})
      end

    headers =
      for headers <- [
            ~s({"x-client-info":"v"}),
            ~s({"x-client-info":"v","x-client-info":"w"}),
            ~s({"X-Client-Info":"v"}),
            "{}",
            "[]",
            "",
            nil,
            "not json",
            ~s({"x-client-info":null}),
            ~s({"x-client-info":"\\u0000"}),
            ~s({"x-client-info":1})
          ],
          sql <- [
            "current_setting('request.headers', true)::jsonb ->> 'x-client-info' = 'v'",
            "current_setting('request.headers', true)::jsonb ->> 'x-client-info' IS NULL",
            "current_setting('request.headers', true) IS NULL",
            "nullif(current_setting('request.headers', true), '') IS NULL",
            "current_setting('request.headers', true)::json ->> 'x-client-info' = 'v'"
          ] do
        expression_case(sql, headers: headers)
      end

    settings =
      for sql <- [
            "current_setting('role', true) = 'authenticated'",
            "current_setting('role', true) = 'anon'",
            "current_setting('request.jwt.claim.role', true) = 'authenticated'",
            "current_setting('request.jwt.claim.role', true) IS NULL",
            "current_setting('request.jwt.claim.sub', true) = '#{@own}'",
            "current_setting('request.jwt.claim.sub', true) = ''",
            "current_setting('request.jwt.claim.sub', true) IS NULL",
            "nullif(current_setting('request.jwt.claim.sub', true), '') IS NULL",
            "current_setting('realtime.topic', true) = 'room:1'",
            "current_setting('realtime.topic', true) = ''",
            "current_setting('Request.JWT.Claims', true) IS NULL",
            "current_setting('REQUEST.JWT.CLAIM.SUB', true) = '#{@own}'",
            "current_setting('request.jwt.claims', true) = ''",
            "current_setting('request.jwt.claims', true) IS NOT NULL"
          ],
          opts <- [
            [],
            [sub: nil],
            [sub: ""],
            [role: "anon"],
            [topic: nil],
            [topic: ""],
            [claims: nil],
            [claims: ""],
            [claim_role: nil]
          ] do
        expression_case(sql, opts)
      end

    from_jason ++ from_raw ++ usual ++ booleans ++ headers ++ settings
  end

  defp cases(:regex) do
    topics = [
      "public:lobby",
      "PUBLIC:LOBBY",
      "Public:Lobby",
      "xpublic:lobbyy",
      "room:1",
      "",
      nil,
      "a.b",
      "aXb",
      "x*y",
      "a\\b",
      "it's",
      "tab\there",
      "line\nbreak"
    ]

    patterns = [
      "public:lobby",
      "PUBLIC:LOBBY",
      "lobby",
      "LOBBY",
      "",
      "x",
      "a.b",
      "a|b",
      "x*",
      "^public",
      "lobby$",
      "[a-z]",
      "\\d",
      "(?i)PUBLIC",
      "***:public",
      "***=public",
      "a{2}",
      "a}b",
      "a]b",
      ":",
      "_",
      "%",
      "-",
      " ",
      "'",
      "\\",
      "e",
      "É",
      "é",
      "İ",
      "ſ",
      "K"
    ]

    ascii =
      for topic <- topics, pattern <- patterns, operator <- ["~", "~*"] do
        expression_case("realtime.topic() #{operator} #{lit(pattern)}", topic: topic)
      end

    unicode_topics = [
      "café",
      "CAFÉ",
      "Café",
      "İstanbul",
      "istanbul",
      "ISTANBUL",
      "Kelvin K",
      "kelvin k",
      "straße",
      "STRASSE",
      "ſs",
      "Σίσυφος",
      "ΣΊΣΥΦΟΣ"
    ]

    unicode_patterns = ["é", "É", "caf", "CAF", "i", "I", "k", "K", "s", "S", "ss", "σ", "Σ", ""]

    unicode =
      for topic <- unicode_topics, pattern <- unicode_patterns, operator <- ["~", "~*"] do
        expression_case("realtime.topic() #{operator} #{lit(pattern)}", topic: topic)
      end

    others =
      for sql <- [
            "realtime.topic() ~ NULL::text",
            "realtime.topic() ~* NULL::text",
            "NULL::text ~ 'a'",
            "'abc' ~ 'b'",
            "'ABC' ~* 'b'",
            "'ABC' ~ 'b'",
            "extension ~ 'cast'",
            "extension ~* 'CAST'",
            "NOT (realtime.topic() ~ 'a')",
            "NOT (realtime.topic() ~* 'A')",
            "realtime.topic() ~ 'a' AND extension ~* 'B'",
            "realtime.topic() !~ 'a'",
            "realtime.topic() !~* 'a'",
            "realtime.topic() ~ extension",
            "realtime.topic() ~ ('a' || extension)",
            "realtime.topic() ~ auth.role()"
          ],
          topic <- ["a", "A", "", nil],
          extension <- ["broadcast", nil] do
        expression_case(sql, topic: topic, extension: extension)
      end

    ascii ++ unicode ++ others
  end

  defp cases(:literals) do
    # uuid_in's accepted forms, from uuid.sql. A literal is deparsed to its canonical form.
    uuid_forms = [
      "11111111-1111-1111-1111-111111111111",
      "{11111111-1111-1111-1111-111111111111}",
      "11111111111111111111111111111111",
      "1111-1111-1111-1111-1111-1111-1111-1111",
      "{1111-1111-1111-1111-1111-1111-1111-1111}",
      "A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11",
      "a0eebc99-9c0b4ef8-bb6d6bb9-bd380a11",
      "{a0eebc99-9c0b4ef8-bb6d6bb9-bd380a11}",
      "a0eebc999c0b4ef8bb6d6bb9bd380a11",
      "a0ee-bc99-9c0b-4ef8-bb6d-6bb9-bd38-0a11"
    ]

    uuid_literals =
      for form <- uuid_forms,
          sub <- ["a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "11111111-1111-1111-1111-111111111111", nil],
          sql <- [
            "auth.uid() = #{lit(form)}::uuid",
            "#{lit(form)}::uuid <> auth.uid()",
            "(#{lit(form)}::uuid)::text = 'x'"
          ] do
        expression_case(sql, sub: sub)
      end

    boolean_literals =
      for form <- ~w(t true yes on 1 f false no off 0 y n),
          sql <- [
            "#{lit(form)}::boolean",
            "#{lit(form)}::boolean AND extension = 'broadcast'",
            "NOT #{lit(form)}::boolean"
          ] do
        expression_case(sql)
      end

    jsonb_literals =
      for json <- [
            ~s({"x": "v"}),
            ~s({"x":"v"}),
            ~s({"x":"first","x":"v"}),
            ~s({"x":1e2}),
            ~s({"x": 1.50}),
            ~s({"x": true}),
            ~s({"x": null}),
            ~s({"x": {"a": [1, 2, {"b": null}]}}),
            ~s({"x": "caf\\u00e9"}),
            ~s({"x": "\\ud83d\\ude00"}),
            ~s({"x": "a\\nb"}),
            ~s({"x": "a\\"b"}),
            ~s({"x": "a\\\\b"}),
            ~s({"x": "it's"}),
            "{}",
            "[]",
            ~s(["x"]),
            ~s("x"),
            "5",
            "null"
          ],
          sql <- [
            "#{lit(json)}::jsonb ->> 'x' = 'v'",
            "#{lit(json)}::jsonb ->> 'x' IS NULL",
            "#{lit(json)}::jsonb ->> 'x' = '100'",
            "#{lit(json)}::jsonb ->> 'x' = 'café'"
          ] do
        expression_case(sql)
      end

    # An operand that raises (the cast of a sub that isn't a uuid) next to one that would decide. Postgres
    # evaluates the left side first and raises where it is reached, so the evaluator has to fall back
    # (a decided answer there is a mismatch), and also where it isn't reached, it can't know that
    raising_operand =
      [
        expression_case("(auth.uid())::text = 'x' OR extension = 'broadcast'", sub: "user_2abc"),
        expression_case("(auth.uid())::text = 'x' AND extension = 'nope'", sub: "user_2abc"),
        expression_case("NOT ((auth.uid())::text = 'x' AND extension = 'nope')", sub: "user_2abc"),
        # and where it is not reached
        expression_case("extension = 'broadcast' OR (auth.uid())::text = 'x'", sub: "user_2abc"),
        expression_case("extension = 'nope' AND (auth.uid())::text = 'x'", sub: "user_2abc"),
        expression_case("true OR (auth.uid())::text = 'x'", sub: "user_2abc"),
        expression_case("false AND (auth.uid())::text = 'x'", sub: "user_2abc"),
        expression_case("(auth.uid())::text = 'x' OR true", sub: "user_2abc"),
        expression_case("(auth.uid())::text = 'x' AND false", sub: "user_2abc"),
        # both sides raise, or neither decides
        expression_case("(auth.uid())::text = 'x' OR (auth.uid())::text = 'y'", sub: "user_2abc"),
        expression_case("(auth.uid())::text = 'x' AND extension = 'broadcast'", sub: "user_2abc"),
        expression_case("(auth.uid())::text = 'x' OR extension = 'nope'", sub: "user_2abc")
      ]

    # Strings, from strings.sql
    strings =
      for sql <- [
            "'abc' || 'def' = 'abcdef'",
            "'abc' || NULL IS NULL",
            "'' || '' = ''",
            "'a' = 'a '",
            "'a' = 'A'",
            "'' = ''",
            "NULL::text = NULL::text",
            "NULL::text IS NULL",
            "'a' <> 'b'",
            "'a' <> NULL",
            "NOT ('a' = 'b')",
            "'é' = 'é'",
            "'é' || 'e' = 'ée'"
          ] do
        expression_case(sql)
      end

    uuid_literals ++ boolean_literals ++ jsonb_literals ++ raising_operand ++ strings
  end

  defp claim_text(value) when is_binary(value), do: value
  defp claim_text(nil), do: "null"
  defp claim_text(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp claim_text(value), do: Jason.encode!(value)

  ## Level 2 scenarios

  defp policy_sql(name, definition), do: ~s(CREATE POLICY "#{name}" ON realtime.messages #{definition})

  # What the subs of the user-channel grid are: a spelling of a uuid, or not
  defp sub_kind(nil), do: :missing
  defp sub_kind(""), do: :empty
  defp sub_kind("user_2abc"), do: :not_a_uuid
  defp sub_kind(_uuid), do: :valid_uuid

  # User channels. The topics are for a user whose sub is @own, and subs are spellings of it
  defp user_channel_grid(form, flavor) do
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
        "user channels #{form}, #{@flavor_labels[flavor]}",
        "user channels #{form} (#{@flavor_labels[flavor]}) #{role}, topic: #{topic_label}, sub: #{sub_label}",
        policies,
        Keyword.merge([role: role, topic: topic, sub: sub], claim_opts),
        functions: flavor,
        meta: %{
          topic: topic_label,
          sub: sub_label,
          sub_kind: sub_kind(sub),
          ascii_topic: byte_size(topic) == String.length(topic)
        },
        user_channels: :grid
      )
    end
  end

  # The table of the unit tests, for both bodies of auth.uid(), against all five policies, and the
  # cases the unit tests say depend on the order the planner puts the clauses in: the cast of a sub that
  # isn't a uuid is only reached if `extension IN (...)` doesn't come first. What Postgres does depends
  # on the policies that exist, so they are asked for plain, initplan and both.
  defp user_channel_table_scenarios do
    policies = SqlLogexPolicies.user_channel_policies()

    planner_order =
      for {label, policies} <- [
            {"plain", SqlLogexPolicies.user_channel_policies(:plain)},
            {"initplan", SqlLogexPolicies.user_channel_policies(:initplan)},
            {"plain and initplan", policies}
          ],
          flavor <- [:legacy, :supabase_auth],
          topic <- ["user:user_2abc", "public:lobby"] do
        scenario(
          "user channels planner order",
          "user channels #{label} policies, #{@flavor_labels[flavor]}, topic #{topic}, sub user_2abc, extensions outside the list",
          policies,
          [topic: topic, sub: "user_2abc"],
          functions: flavor,
          extensions: ["persistence", "postgres_changes"],
          meta: %{policies: label, flavor: flavor, topic: topic},
          user_channels: :planner
        )
      end

    table =
      for {operation, rows} <- [read: @user_channel_reads, write: @user_channel_writes],
          row <- rows,
          flavor <- [:legacy, :supabase_auth] do
        extensions = Map.get(row, :extensions, @extensions)

        expect =
          if flavor == :supabase_auth and Map.has_key?(row, :supabase_auth), do: row.supabase_auth, else: row.expect

        scenario(
          "user channels table, #{@flavor_labels[flavor]}",
          "user channels table #{operation}: #{row.name} (#{@flavor_labels[flavor]})",
          policies,
          [role: Map.get(row, :role, "authenticated"), topic: row.topic, sub: row.sub],
          functions: flavor,
          extensions: extensions,
          table: Map.new(extensions, &{{operation, &1}, expect}),
          user_channels: :table
        )
      end

    table ++ planner_order
  end

  defp generator_scenarios do
    generators = fn names, params -> SqlLogexPolicies.generator_statements(names, params) end

    broken_setup = [
      "CREATE FUNCTION public.test_log_error() RETURNS boolean AS $$ BEGIN RAISE EXCEPTION 'test error'; END $$ LANGUAGE plpgsql"
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
          "presence for sub, sub #{inspect(sub)}, topic #{topic} (#{@flavor_labels[flavor]})",
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
          "matching user sub, sub #{inspect(sub)} (#{@flavor_labels[flavor]})",
          generators.([:authenticated_read_matching_user_sub, :authenticated_write_matching_user_sub], %{sub: @own}),
          [sub: sub],
          functions: flavor
        )
      end

    matching_role =
      for role <- ["authenticated", "anon", "service_role"], flavor <- [:legacy, :supabase_auth] do
        scenario(
          "generators",
          "matching user role, #{role} (#{@flavor_labels[flavor]})",
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

  defp combination_scenarios do
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
      # The probe row of realtime.authorize has the defaults of the other columns, which aren't modelled
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

  # Everything the evaluator doesn't model has to be a fallback, not an answer. The setups change
  # the database in the transaction of the scenario, and are rolled back with it.
  defp snapshot_scenarios do
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
       ]},
      {"a policy for a role authenticated is a member of, without inheritance",
       [
         "CREATE ROLE sql_logex_team NOLOGIN",
         "GRANT sql_logex_team TO authenticated WITH INHERIT FALSE",
         policy_sql("team", "FOR ALL TO sql_logex_team USING (true) WITH CHECK (true)")
       ]}
    ]

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

  # realtime.authorize reads the table in every call, write-only calls included. So whatever makes that
  # SELECT fail makes the writes fail: a missing SELECT privilege, and a SELECT policy that Postgres can't
  # plan. The evaluator decides a write only from what it can read of the SELECT policies: it falls back
  # for a missing grant, and for a policy it doesn't fully model, see SqlLogex.PolicySet.
  defp select_dependent_scenarios do
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

  # A policy that raises next to one that allows. The permissive policies are evaluated in reverse name
  # order, so b_raises before a_allow. Whether that makes the call raise depends on what Postgres does with
  # `b_raises OR a_allow` before it runs. The evaluator can't tell, so it has to fall back where Postgres
  # raises, whatever the other policy says: a decided answer there is a mismatch.
  defp raising_policy_scenarios do
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

  ## Report

  defp report(results) do
    by_level = Enum.group_by(results, & &1.level)

    [
      "",
      "== sql_logex differential report ==",
      level_section("Level 1, expressions", Map.get(by_level, 1, [])),
      level_section("Level 2, policy sets through realtime.authorize", Map.get(by_level, 2, [])),
      user_channel_section(Enum.filter(results, &(&1.user_channels == :grid))),
      table_section(Enum.filter(results, &(&1.user_channels == :table))),
      planner_section(Enum.filter(results, &(&1.user_channels == :planner))),
      ""
    ]
    |> Enum.join("\n")
  end

  @classes [:match, :fallback, :mismatch, :crash]

  defp level_section(title, []), do: "\n#{title}: no results"

  defp level_section(title, results) do
    counts = Enum.frequencies_by(results, & &1.class)
    count = fn class -> Map.get(counts, class, 0) end

    matches = Enum.filter(results, &(&1.class == :match))
    fallbacks = Enum.filter(results, &(&1.class == :fallback))
    values = Enum.frequencies(for %{pg: {:ok, value}} <- matches, do: value)

    group_lines =
      results
      |> Enum.group_by(& &1.group)
      |> Enum.sort()
      |> Enum.map(fn {group, in_group} ->
        frequencies = Enum.frequencies_by(in_group, & &1.class)
        classes = for class <- @classes, frequencies[class], do: "#{class} #{frequencies[class]}"
        "    #{group}: #{length(in_group)} (#{Enum.join(classes, ", ")})"
      end)

    """

    #{title}: #{length(results)} cases
      match     #{count.(:match)}   (Postgres returned true #{values[true] || 0}, false #{values[false] || 0}, NULL #{values[nil] || 0})
      fallback  #{count.(:fallback)}   (postgres returned a value: #{Enum.count(fallbacks, &(&1.sub == :postgres_value))}; postgres raised: #{Enum.count(fallbacks, &(&1.sub != :postgres_value))}, of which predicted by the evaluator: #{Enum.count(fallbacks, &(&1.sub == :postgres_error_predicted))}, not predicted: #{Enum.count(fallbacks, &(&1.sub == :postgres_error))}, with another sqlstate: #{Enum.count(fallbacks, &(&1.sub == :postgres_error_other_sqlstate))})
      mismatch  #{count.(:mismatch)}
      crash     #{count.(:crash)}
      groups:
    #{Enum.join(group_lines, "\n")}
      fallback reasons:
    #{reason_lines(fallbacks, "    ")}\
    """
  end

  defp reason_lines(fallbacks, indent) do
    fallbacks
    |> Enum.frequencies_by(&reason_key(&1.ex))
    |> Enum.sort_by(fn {key, count} -> {-count, key} end)
    |> Enum.take(25)
    |> Enum.map_join("\n", fn {key, count} -> "#{indent}#{String.pad_leading(Integer.to_string(count), 5)}  #{key}" end)
  end

  defp reason_key({:unsupported, reason}), do: reason_key(reason)
  defp reason_key({:raises, state, _detail}), do: "raises #{state}"
  defp reason_key({:unparsed, raw}), do: "unparsed #{inspect(String.slice(raw, 0, 60))}"
  defp reason_key(reason), do: inspect(reason, limit: 6, printable_limit: 60)

  defp user_channel_section([]), do: ""

  defp user_channel_section(results) do
    scenarios = Enum.group_by(results, & &1.scenario)
    decided = Enum.filter(results, &match?({:value, _}, &1.ex))
    fallbacks = Enum.reject(results, &match?({:value, _}, &1.ex))

    scenario_states =
      Enum.frequencies_by(scenarios, fn {_name, decisions} ->
        case Enum.count(decisions, &match?({:value, _}, &1.ex)) do
          0 -> :fell_back
          n when n == length(decisions) -> :decided
          _ -> :partly_decided
        end
      end)

    by_role =
      results
      |> Enum.group_by(& &1.role)
      |> Enum.sort()
      |> Enum.map(fn {role, in_role} ->
        "    #{role}: #{decided_share(in_role)}, scenarios #{scenario_shares(in_role)}"
      end)

    authenticated = Enum.filter(results, &(&1.role == "authenticated"))

    by_meta = fn key ->
      authenticated
      |> Enum.group_by(& &1.meta[key])
      |> Enum.sort()
      |> Enum.map_join("\n", fn {label, in_label} -> "      #{label}: #{decided_share(in_label)}" end)
    end

    valid_sub = Enum.filter(authenticated, &(&1.meta.sub_kind == :valid_uuid))
    valid_or_missing_sub = Enum.filter(authenticated, &(&1.meta.sub_kind in [:valid_uuid, :missing]))

    """

    User channels, the grid (topics x subs x roles, plain and initplan, both auth.uid() bodies), the evaluator by default
      scenarios:  #{map_size(scenarios)}   fully decided #{scenario_states[:decided] || 0} (#{percent(scenario_states[:decided] || 0, map_size(scenarios))}), partly decided #{scenario_states[:partly_decided] || 0}, fully fell back #{scenario_states[:fell_back] || 0}
      decisions:  #{length(results)}   decided #{length(decided)} (#{percent(length(decided), length(results))}), fell back #{length(fallbacks)} (#{percent(length(fallbacks), length(results))})
      authenticated with a valid sub (a spelling of a uuid), #{decided_share(valid_sub)}
        and an ASCII topic, #{decided_share(Enum.filter(valid_sub, & &1.meta.ascii_topic))}
      authenticated with a valid or a missing sub, #{decided_share(valid_or_missing_sub)}
      by role:
    #{Enum.join(by_role, "\n")}
      authenticated, by sub:
    #{by_meta.(:sub)}
      authenticated, by topic:
    #{by_meta.(:topic)}
      fallback reasons:
    #{reason_lines(fallbacks, "    ")}\
    """
  end

  defp decided_share(results) do
    decided = Enum.count(results, &match?({:value, _}, &1.ex))
    "#{decided} of #{length(results)} decisions decided (#{percent(decided, length(results))})"
  end

  defp scenario_shares(results) do
    states =
      results
      |> Enum.group_by(& &1.scenario)
      |> Enum.frequencies_by(fn {_name, decisions} ->
        case Enum.count(decisions, &match?({:value, _}, &1.ex)) do
          0 -> :fell_back
          n when n == length(decisions) -> :decided
          _ -> :partly_decided
        end
      end)

    total = Enum.sum(Map.values(states))
    decided = states[:decided] || 0

    "#{decided} of #{total} fully decided (#{percent(decided, total)}), #{states[:partly_decided] || 0} partly, #{states[:fell_back] || 0} fell back"
  end

  # Postgres against the evaluator, for the cases the unit tests say depend on the order of the planner
  defp planner_section([]), do: ""

  defp planner_section(results) do
    lines =
      results
      |> Enum.filter(&(&1.meta.flavor == :legacy))
      |> Enum.sort_by(&{&1.meta.topic, &1.meta.policies, &1.operation, &1.extension})
      |> Enum.map_join("\n", fn result ->
        "    topic #{result.meta.topic}, #{result.meta.policies} policies, #{result.operation} #{result.extension}: postgres #{format_postgres(result.pg)}; evaluator #{format_evaluator(result.ex)}"
      end)

    """

    User channels, planner order: sub user_2abc, extensions outside the list (legacy auth.uid())
    #{lines}
    """
  end

  defp table_section([]), do: ""

  defp table_section(results) do
    verdicts = Enum.frequencies_by(results, &table_verdict/1)

    # Where the unit tests expect a fallback because something raises, and Postgres returned a value
    conservative_rows =
      results
      |> Enum.filter(&(table_verdict(&1) == :conservative))
      |> Enum.map_join("\n", fn result ->
        "    #{result.name}: expected #{inspect(result.table)}, postgres #{format_postgres(result.pg)}"
      end)

    """

    User channels, the decision table of the unit tests: #{length(results)} decisions, #{verdicts[:agrees] || 0} agree with Postgres, #{verdicts[:disagrees] || 0} disagree, #{verdicts[:conservative] || 0} are a fallback where Postgres returned a value, #{verdicts[:not_checked] || 0} not checkable (a fallback of the evaluator)
      the fallbacks where Postgres returned a value, because the evaluator can't know the part that raises isn't reached:
    #{conservative_rows}
    """
  end

  defp percent(_part, 0), do: "n/a"
  defp percent(part, whole), do: "#{Float.round(part * 100 / whole, 1)}%"

  ## The table of the unit tests against Postgres

  # What Postgres said has to be consistent with what the unit tests expect of a decision. A decision has to
  # be what Postgres returned. A fallback because something raises is right if Postgres raised that, and
  # conservative if it returned a value, as the evaluator can't know it doesn't reach what raises.
  # Neither fails the test, only a decision that isn't what Postgres returned.
  defp table_verdict(%{table: nil}), do: :not_checked

  defp table_verdict(%{table: decision, pg: pg}) when decision in [:allow, :deny],
    do: if(pg == {:ok, decision == :allow}, do: :agrees, else: :disagrees)

  defp table_verdict(%{table: {:fallback, {:unsupported, {:raises, state, _}}}, pg: pg}) do
    case pg do
      {:error, _sqlstate, ^state, _message} -> :agrees
      {:error, _sqlstate, _other, _message} -> :disagrees
      {:ok, _value} -> :conservative
    end
  end

  defp table_verdict(%{table: {:fallback, _reason}}), do: :not_checked
end
