defmodule PolicyEval.Postgres.DecisionsTest do
  # Level 2 of the differential tests: `PolicyEval.decide/3` decides allow or deny for a policy set
  # as Postgres row-level security does, or falls back when it cannot be sure. Postgres is the
  # oracle. Every scenario runs through both, and PolicyEval.Differential compares the answers.
  #
  #   mix test test/postgres/decisions_test.exs
  #   POLICY_EVAL_REPORT=1 mix test test/postgres/decisions_test.exs   # coverage report
  #
  # The scenarios are in PolicyEval.Test.ExampleScenarios. The decision table of the unit tests
  # (policy_set_test.exs) is among them, so Postgres also checks what the unit tests expect, see
  # PolicyEval.Test.Collector.
  use ExUnit.Case, async: false

  alias PolicyEval.Differential
  alias PolicyEval.Snapshot
  alias PolicyEval.Test.Collector
  alias PolicyEval.Test.Postgres
  alias PolicyEval.Test.ExampleDatabase
  alias PolicyEval.Test.ExampleProfile
  alias PolicyEval.Test.ExampleScenarios

  @moduletag :postgres
  @moduletag timeout: 600_000

  @profile ExampleProfile.profile()

  @insert_probes """
  INSERT INTO app.docs (team, kind)
  SELECT $1::text, kind FROM unnest($2::text[]) AS kind
  RETURNING id, kind
  """

  @select_probes "SELECT id FROM app.docs WHERE id = ANY($1::uuid[])"

  @insert "INSERT INTO app.docs (team, kind) VALUES ($1, $2)"

  setup_all do
    %{collector: Collector.start(:decisions)}
  end

  setup do
    %{conn: start_supervised!(Postgres)}
  end

  for form <- [:plain, :initplan], flavor <- [:simple, :fallback] do
    test "personal teams: #{form} policies, #{ExampleScenarios.flavor_label(flavor)} bodies", context do
      run(context, ExampleScenarios.personal_team_grid(unquote(form), unquote(flavor)))
    end
  end

  test "personal teams: the decision table of the unit tests", context do
    run(context, ExampleScenarios.personal_team_table_scenarios())
  end

  test "typical policies", context do
    run(context, ExampleScenarios.typical_scenarios())
  end

  test "combining policies", context do
    run(context, ExampleScenarios.combination_scenarios())
  end

  test "what the snapshot has to rule out", %{conn: conn} = context do
    run(context, ExampleScenarios.snapshot_scenarios(Postgres.server_version_num(conn)))
  end

  test "a SELECT that fails doesn't change a write", context do
    run(context, ExampleScenarios.write_ignores_select_scenarios())
  end

  test "a policy that raises next to one that allows", context do
    run(context, ExampleScenarios.raising_policy_scenarios())
  end

  defp run(%{conn: conn, collector: collector}, scenarios) do
    Collector.finish(collector, Enum.flat_map(scenarios, &run_scenario(conn, &1)))
  end

  # In a transaction that rolls back: the setup, the policies of the scenario in place of the ones
  # on the table, then the snapshot input and the answers of Postgres. Then the library decides
  # each question, and PolicyEval.Differential compares the two answers.
  defp run_scenario(conn, scenario) do
    table = ExampleDatabase.table()

    {input, answers} =
      Postgres.rolled_back(conn, fn conn ->
        Enum.each(scenario.setup, &execute!(conn, scenario, &1))

        %{rows: rows} =
          Postgrex.query!(conn, "SELECT polname FROM pg_policy WHERE polrelid = $1::text::regclass", [table])

        Enum.each(rows, fn [policy] ->
          execute!(conn, scenario, ~s(DROP POLICY "#{String.replace(policy, ~s("), ~s(""))}" ON #{table}))
        end)

        Enum.each(scenario.policies, &execute!(conn, scenario, &1))
        {Postgres.read(conn, table, @profile), outcomes(conn, scenario)}
      end)

    snapshot = Snapshot.new(input, @profile)

    for {{_operation, kind} = key, operation, env} <- scenario.questions do
      Differential.compare(Map.fetch!(answers, key), Differential.decide(snapshot, env, operation),
        name: "#{scenario.name} [#{operation} #{kind}]",
        group: scenario.group,
        detail: detail(scenario, key, env),
        meta: Map.merge(scenario.meta, %{scenario: scenario.name, key: key})
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

  ## The oracle

  # What Postgres decides for each {operation, kind}, asked the way that the profile describes.
  # One call asks for all of them. As the table owner, it inserts a probe row for each read. Then,
  # as the role and with the settings of the case, one SELECT reads the probes back, and each write
  # is an INSERT in a savepoint. insufficient_privilege, a missing grant or a failed WITH CHECK,
  # denies a write. A call without reads runs no SELECT, so a write depends only on the INSERT
  # policies, as PolicyEval.PolicySet assumes. Any other error fails the whole call, so then each
  # one is asked for on its own, to tell which one raised.
  defp outcomes(conn, %{env: env, kinds: kinds}) do
    case ask(conn, env, kinds, kinds) do
      {:ok, read_allowed, write_allowed} ->
        Map.merge(zip(:read, kinds, read_allowed), zip(:write, kinds, write_allowed))

      {:error, _error} ->
        for operation <- [:read, :write], kind <- kinds, into: %{} do
          {reads, writes} = if operation == :read, do: {[kind], []}, else: {[], [kind]}

          case ask(conn, env, reads, writes) do
            {:ok, [allowed], []} -> {{operation, kind}, {:ok, allowed}}
            {:ok, [], [allowed]} -> {{operation, kind}, {:ok, allowed}}
            {:error, error} -> {{operation, kind}, error}
          end
        end
    end
  end

  defp zip(operation, kinds, allowed) do
    kinds |> Enum.zip(allowed) |> Map.new(fn {kind, value} -> {{operation, kind}, {:ok, value}} end)
  end

  # In a savepoint that rolls back, so that the probes, the role and an error do not stay
  defp ask(conn, env, read_kinds, write_kinds) do
    Postgrex.query!(conn, "SAVEPOINT ask", [])

    try do
      %{rows: probes} = Postgrex.query!(conn, @insert_probes, [env.row_team, read_kinds])
      ExampleScenarios.set_settings!(conn, env)

      with {:ok, visible} <- read_back(conn, probes),
           {:ok, write_allowed} <- writes(conn, env, write_kinds) do
        id_by_kind = Map.new(probes, fn [id, kind] -> {kind, id} end)
        {:ok, Enum.map(read_kinds, &MapSet.member?(visible, id_by_kind[&1])), write_allowed}
      end
    after
      Postgrex.query!(conn, "ROLLBACK TO SAVEPOINT ask", [])
      Postgrex.query!(conn, "RELEASE SAVEPOINT ask", [])
    end
  end

  # The ids of the probes that the role can see. Without probes, no SELECT runs.
  defp read_back(_conn, []), do: {:ok, MapSet.new()}

  defp read_back(conn, probes) do
    with {:ok, %{rows: rows}} <- query(conn, @select_probes, [Enum.map(probes, &hd/1)]) do
      {:ok, MapSet.new(rows, &hd/1)}
    end
  end

  defp writes(conn, env, kinds) do
    Enum.reduce_while(kinds, {:ok, []}, fn kind, {:ok, allowed} ->
      case Postgrex.query(conn, @insert, [env.row_team, kind], mode: :savepoint) do
        {:ok, _result} -> {:cont, {:ok, allowed ++ [true]}}
        {:error, %Postgrex.Error{postgres: %{code: :insufficient_privilege}}} -> {:cont, {:ok, allowed ++ [false]}}
        {:error, %Postgrex.Error{} = error} -> {:halt, {:error, Postgres.error(error)}}
      end
    end)
  end

  defp query(conn, statement, params) do
    case Postgrex.query(conn, statement, params) do
      {:ok, result} -> {:ok, result}
      {:error, %Postgrex.Error{} = error} -> {:error, Postgres.error(error)}
    end
  end
end
