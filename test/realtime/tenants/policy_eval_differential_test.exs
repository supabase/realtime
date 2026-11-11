defmodule Realtime.Tenants.PolicyEvalDifferentialTest do
  # policy_eval decides allow/deny for a join exactly as `realtime.authorize` does, and falls back
  # whenever it can't be sure. Postgres is the oracle: every scenario runs through both, and
  # PolicyEval.Differential compares the answers.
  #
  #   mix test test/realtime/tenants/policy_eval_differential_test.exs
  #   POLICY_EVAL_REPORT=1 mix test test/realtime/tenants/policy_eval_differential_test.exs   # coverage report
  #
  # The scenarios are in test/support/policy_eval_scenarios.ex. This test uses what production uses:
  # a tenant database, the loader (Realtime.Tenants.PolicyEvalLoader), the profile that Realtime
  # ships, and `realtime.authorize`, which Realtime calls on a join. A call that raises is asked
  # again for one extension at a time, to tell which one raised.
  use Realtime.DataCase, async: true

  alias PolicyEval.Differential
  alias PolicyEval.Snapshot
  alias Realtime.Database
  alias Realtime.Tenants.PolicyEvalLoader
  alias Realtime.Tenants.PolicyEvalProfile

  @moduletag timeout: 600_000

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

  # Collects the results of all tests, for the report
  setup_all do
    {:ok, collected} = Agent.start(fn -> [] end)

    on_exit(fn ->
      results = Agent.get(collected, & &1)
      Agent.stop(collected)

      if System.get_env("POLICY_EVAL_REPORT") == "1",
        do: IO.puts("\n" <> Differential.report(results, "policy_eval through realtime.authorize"))
    end)

    %{collected: collected}
  end

  setup do
    tenant = TestTenantDb.checkout_tenant(run_migrations: true)
    {:ok, db_conn} = Database.connect(tenant, "realtime_test", :stop)
    %{db_conn: db_conn}
  end

  for form <- [:plain, :initplan], flavor <- [:legacy, :supabase_auth] do
    test "user channels: #{form} policies, #{PolicyEvalScenarios.flavor_label(flavor)} auth functions", context do
      run(context, PolicyEvalScenarios.user_channel_grid(unquote(form), unquote(flavor)))
    end
  end

  test "generator policies", context do
    run(context, PolicyEvalScenarios.generator_scenarios())
  end

  test "combining policies", context do
    run(context, PolicyEvalScenarios.combination_scenarios())
  end

  test "what the snapshot has to rule out", %{db_conn: db_conn} = context do
    %{rows: [[version_num]]} = Postgrex.query!(db_conn, "SELECT current_setting('server_version_num')::int", [])
    run(context, PolicyEvalScenarios.snapshot_scenarios(version_num))
  end

  test "a SELECT that fails doesn't change a write", context do
    run(context, PolicyEvalScenarios.write_ignores_select_scenarios())
  end

  test "a policy that raises next to one that allows", context do
    run(context, PolicyEvalScenarios.raising_policy_scenarios())
  end

  defp run(%{db_conn: db_conn, collected: collected}, scenarios) do
    results = Enum.flat_map(scenarios, &run_scenario(db_conn, &1))
    Agent.update(collected, &(results ++ &1))
    Differential.verify!(results)
  end

  # In a transaction that rolls back: the setup, the policies of the scenario in place of the ones
  # on realtime.messages, then the snapshot input and the answers of realtime.authorize. Then
  # policy_eval decides each question, and PolicyEval.Differential compares the two answers.
  defp run_scenario(conn, scenario) do
    {:error, {:rolled_back, {input, answers}}} =
      Postgrex.transaction(
        conn,
        fn conn ->
          Enum.each(scenario.setup, &execute!(conn, scenario, &1))

          %{rows: rows} =
            Postgrex.query!(conn, "SELECT polname FROM pg_policy WHERE polrelid = 'realtime.messages'::regclass", [])

          Enum.each(rows, fn [policy] ->
            execute!(conn, scenario, ~s(DROP POLICY "#{String.replace(policy, ~s("), ~s(""))}" ON realtime.messages))
          end)

          Enum.each(scenario.policies, &execute!(conn, scenario, &1))
          Postgrex.rollback(conn, {:rolled_back, {PolicyEvalLoader.read(conn), authorize_answers(conn, scenario)}})
        end,
        timeout: 60_000
      )

    snapshot = Snapshot.new(input, PolicyEvalProfile.profile())

    for {{_operation, extension} = key, operation, env} <- scenario.questions do
      Differential.compare(Map.fetch!(answers, key), Differential.decide(snapshot, env, operation),
        name: "#{scenario.name} [#{operation} #{extension}]",
        group: scenario.group,
        detail: detail(scenario, key, env)
      )
    end
  end

  defp execute!(conn, scenario, statement) do
    case Postgrex.query(conn, statement, []) do
      {:ok, _result} -> :ok
      {:error, error} -> raise "#{inspect(scenario.name)}: #{Exception.message(error)}\nwhile running:\n#{statement}"
    end
  end

  defp detail(scenario, key, env) do
    policies = Enum.map(scenario.policies, &("    " <> String.replace(&1, "\n", " ")))

    Enum.join(
      ["  key: #{inspect(key)}", "  policies:"] ++
        policies ++
        ["  settings: #{format_map(env.settings)}", "  row: #{format_map(env.row)}", "  #{scenario.detail}"],
      "\n"
    ) <> "\n"
  end

  defp format_map(map), do: map |> Enum.sort() |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{inspect(v)}" end)

  # What realtime.authorize returns for each {operation, extension}. A policy that raises fails the
  # whole call, so when that happens each is asked for on its own to tell which one raised.
  defp authorize_answers(conn, %{env: env, extensions: extensions}) do
    case authorize(conn, env, extensions, extensions) do
      {:ok, [read_allowed, write_allowed]} ->
        answers(:read, extensions, read_allowed) |> Map.merge(answers(:write, extensions, write_allowed))

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

  defp answers(operation, extensions, allowed) do
    extensions |> Enum.zip(allowed) |> Map.new(fn {extension, value} -> {{operation, extension}, {:ok, value}} end)
  end

  defp authorize(conn, env, read_extensions, write_extensions) do
    params = [env.role, env.topic, env.claims, env.sub, env.headers, read_extensions, write_extensions]

    # In a savepoint, so that a call that raises doesn't abort the transaction
    case Postgrex.query(conn, @authorize_query, params, mode: :savepoint) do
      {:ok, %Postgrex.Result{rows: [[read_allowed, write_allowed]]}} ->
        {:ok, [read_allowed, write_allowed]}

      {:error, %Postgrex.Error{postgres: %{pg_code: sqlstate, code: code, message: message}}} ->
        {:error, {:error, sqlstate, code, message}}
    end
  end
end
