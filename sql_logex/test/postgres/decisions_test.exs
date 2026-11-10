defmodule SqlLogex.Postgres.DecisionsTest do
  # Level 2 of the differential tests: `SqlLogex.decide/3` decides allow or deny for a policy set
  # as Postgres row-level security does, or falls back when it cannot be sure. Postgres is the
  # oracle. Every scenario runs through both, and SqlLogex.Differential compares the answers.
  #
  #   mix test test/postgres/decisions_test.exs
  #   SQL_LOGEX_REPORT=1 mix test test/postgres/decisions_test.exs   # coverage report
  #
  # The scenarios are in SqlLogex.Test.RealtimeScenarios. The decision table of the unit tests
  # (policy_set_test.exs) is among them, so Postgres also checks what the unit tests expect, see
  # SqlLogex.Test.Collector.
  use ExUnit.Case, async: false

  alias SqlLogex.Differential
  alias SqlLogex.Snapshot
  alias SqlLogex.Test.Collector
  alias SqlLogex.Test.Postgres
  alias SqlLogex.Test.RealtimeDatabase
  alias SqlLogex.Test.RealtimeProfile
  alias SqlLogex.Test.RealtimeScenarios

  @moduletag :postgres
  @moduletag timeout: 600_000

  @profile RealtimeProfile.profile()

  @insert_probes """
  INSERT INTO realtime.messages (topic, extension)
  SELECT $1::text, extension FROM unnest($2::text[]) AS extension
  RETURNING id, extension
  """

  @select_probes "SELECT id FROM realtime.messages WHERE id = ANY($1::uuid[])"

  @insert "INSERT INTO realtime.messages (topic, extension) VALUES ($1, $2)"

  setup_all do
    %{collector: Collector.start(:decisions)}
  end

  setup do
    %{conn: start_supervised!(Postgres)}
  end

  for form <- [:plain, :initplan], flavor <- [:legacy, :supabase_auth] do
    test "user channels: #{form} policies, #{RealtimeScenarios.flavor_label(flavor)} auth functions", context do
      run(context, RealtimeScenarios.user_channel_grid(unquote(form), unquote(flavor)))
    end
  end

  test "user channels: the decision table of the unit tests", context do
    run(context, RealtimeScenarios.user_channel_table_scenarios())
  end

  test "generator policies", context do
    run(context, RealtimeScenarios.generator_scenarios())
  end

  test "combining policies", context do
    run(context, RealtimeScenarios.combination_scenarios())
  end

  test "what the snapshot has to rule out", %{conn: conn} = context do
    run(context, RealtimeScenarios.snapshot_scenarios(Postgres.server_version_num(conn)))
  end

  test "writes that fail with the SELECT of the call", context do
    run(context, RealtimeScenarios.select_dependent_scenarios())
  end

  test "a policy that raises next to one that allows", context do
    run(context, RealtimeScenarios.raising_policy_scenarios())
  end

  defp run(%{conn: conn, collector: collector}, scenarios) do
    Collector.finish(collector, Enum.flat_map(scenarios, &run_scenario(conn, &1)))
  end

  # In a transaction that rolls back: the setup, the policies of the scenario in place of the ones
  # on the table, then the snapshot input and the answers of Postgres. Then the library decides
  # each question, and SqlLogex.Differential compares the two answers.
  defp run_scenario(conn, scenario) do
    table = RealtimeDatabase.table()

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

    for {{_operation, extension} = key, operation, env} <- scenario.questions do
      Differential.compare(Map.fetch!(answers, key), Differential.decide(snapshot, env, operation),
        name: "#{scenario.name} [#{operation} #{extension}]",
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

  # What Postgres decides for each {operation, extension}, asked the way that the profile describes.
  # One call asks for all of them. As the table owner, it inserts a probe row for each read. Then,
  # as the role and with the settings of the case, one SELECT reads the probes back, and each write
  # is an INSERT in a savepoint. insufficient_privilege, a missing grant or a failed WITH CHECK,
  # denies a write. The SELECT runs in every call, also without reads, so the writes depend on the
  # SELECT policies too: that is `write_plans_select: true`. Any other error fails the whole call,
  # so then each one is asked for on its own, to tell which one raised.
  defp outcomes(conn, %{env: env, extensions: extensions}) do
    case ask(conn, env, extensions, extensions) do
      {:ok, read_allowed, write_allowed} ->
        Map.merge(zip(:read, extensions, read_allowed), zip(:write, extensions, write_allowed))

      {:error, _error} ->
        for operation <- [:read, :write], extension <- extensions, into: %{} do
          {reads, writes} = if operation == :read, do: {[extension], []}, else: {[], [extension]}

          case ask(conn, env, reads, writes) do
            {:ok, [allowed], []} -> {{operation, extension}, {:ok, allowed}}
            {:ok, [], [allowed]} -> {{operation, extension}, {:ok, allowed}}
            {:error, error} -> {{operation, extension}, error}
          end
        end
    end
  end

  defp zip(operation, extensions, allowed) do
    extensions |> Enum.zip(allowed) |> Map.new(fn {extension, value} -> {{operation, extension}, {:ok, value}} end)
  end

  # In a savepoint that rolls back, so that the probes, the role and an error do not stay
  defp ask(conn, env, read_extensions, write_extensions) do
    Postgrex.query!(conn, "SAVEPOINT ask", [])

    try do
      %{rows: probes} = Postgrex.query!(conn, @insert_probes, [env.row_topic, read_extensions])
      RealtimeScenarios.set_settings!(conn, env)

      with {:ok, %{rows: visible}} <- query(conn, @select_probes, [Enum.map(probes, &hd/1)]),
           {:ok, write_allowed} <- writes(conn, env, write_extensions) do
        visible = MapSet.new(visible, &hd/1)
        id_by_extension = Map.new(probes, fn [id, extension] -> {extension, id} end)
        {:ok, Enum.map(read_extensions, &MapSet.member?(visible, id_by_extension[&1])), write_allowed}
      end
    after
      Postgrex.query!(conn, "ROLLBACK TO SAVEPOINT ask", [])
      Postgrex.query!(conn, "RELEASE SAVEPOINT ask", [])
    end
  end

  defp writes(conn, env, extensions) do
    Enum.reduce_while(extensions, {:ok, []}, fn extension, {:ok, allowed} ->
      case Postgrex.query(conn, @insert, [env.row_topic, extension], mode: :savepoint) do
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
