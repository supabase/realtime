defmodule SqlLogex.Postgres.DecisionsTest do
  # Level 2 of the differential tests: `SqlLogex.decide/3` decides allow or deny for a policy set
  # as Postgres row-level security does, or falls back when it cannot be sure. Postgres is the
  # oracle. Every case runs through both, and the answers are compared, see
  # SqlLogex.Test.Differential.
  #
  #   mix test test/postgres/decisions_test.exs
  #   SQL_LOGEX_REPORT=1 mix test test/postgres/decisions_test.exs   # coverage report
  #
  # The scenarios are in SqlLogex.Test.RealtimeScenarios. Realtime runs the same scenarios
  # through `realtime.authorize`. The decision table of the unit tests (policy_set_test.exs) is
  # among them, so Postgres also checks what the unit tests expect.
  use ExUnit.Case, async: false

  alias SqlLogex.Test.Differential
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
    %{collector: Differential.start_collector("plain row-level security")}
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
    oracle = %{
      prepare_functions: &prepare_functions!/2,
      read: &Postgres.read(&1, RealtimeDatabase.table(), @profile),
      outcomes: &outcomes/3,
      profile: @profile
    }

    Differential.finish(collector, Enum.flat_map(scenarios, &RealtimeScenarios.run(conn, &1, oracle)))
  end

  defp prepare_functions!(_conn, :legacy), do: :ok

  defp prepare_functions!(conn, :supabase_auth),
    do: Postgrex.query!(conn, RealtimeDatabase.supabase_auth_functions_statement(), [])

  ## The oracle

  # What Postgres decides for each {operation, extension}, asked the way that the profile describes.
  # One call asks for all of them. As the table owner, it inserts a probe row for each read. Then,
  # as the role and with the settings of the case, one SELECT reads the probes back, and each write
  # is an INSERT in a savepoint. insufficient_privilege, a missing grant or a failed WITH CHECK,
  # denies a write. The SELECT runs in every call, also without reads, so the writes depend on the
  # SELECT policies too: that is `write_plans_select: true`. Any other error fails the whole call,
  # so then each one is asked for on its own, to tell which one raised.
  defp outcomes(conn, env, extensions) do
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
