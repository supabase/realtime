defmodule SqlLogex.Test.Collector do
  @moduledoc """
  Collects the results of a test module against Postgres (`SqlLogex.Differential`), fails a test
  on each failure, and prints a report when the module is done, if `SQL_LOGEX_REPORT=1`.

  A test fails on a mismatch or a crash (`SqlLogex.Differential.verify!/1`), and also on:

    * a fallback reason without a category (`SqlLogex.Reason.category/1`), so that nobody can add
      a reason without one
    * a decision of the decision table of the unit tests (`meta.table`, see
      `SqlLogex.Test.ExampleScenarios`) that is not what Postgres returned

  The report has extra sections for the personal-team scenarios of the example: the grid, the
  decision table and the planner-order cases.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias SqlLogex.Differential
  alias SqlLogex.Reason

  @titles %{
    expressions: "Level 1, expressions",
    decisions: "Level 2, policy sets through plain row-level security"
  }

  @type t :: %{pid: pid(), level: :expressions | :decisions}

  @doc """
  Starts the collector of a test module. Call it from `setup_all`. `:expressions` is for the
  results of `test/postgres/expressions_test.exs`, `:decisions` for the ones of
  `test/postgres/decisions_test.exs`.
  """
  @spec start(:expressions | :decisions) :: t()
  def start(level) when level in [:expressions, :decisions] do
    {:ok, pid} = Agent.start(fn -> [] end)
    collector = %{pid: pid, level: level}

    ExUnit.Callbacks.on_exit(fn ->
      results = Agent.get(pid, & &1)
      Agent.stop(pid)
      if System.get_env("SQL_LOGEX_REPORT") == "1", do: IO.puts(report(collector, results))
    end)

    collector
  end

  @doc "Records the results for the report, and fails the test on each failure that the moduledoc lists."
  @spec finish(t(), [Differential.result()]) :: :ok
  def finish(collector, results) do
    Agent.update(collector.pid, &(results ++ &1))
    Differential.verify!(results)

    uncategorised = Enum.filter(results, &uncategorised?(collector, &1))
    fail_on(uncategorised, "fallback reasons have no category, see SqlLogex.Reason", &inspect(&1.library))

    disagreeing = Enum.filter(results, &(table_verdict(&1) == :disagrees))

    fail_on(disagreeing, "decisions of the decision table of the unit tests disagree with Postgres", fn result ->
      "the unit tests expect #{inspect(expected(result))}, Postgres #{inspect(result.postgres)}"
    end)
  end

  defp fail_on([], _title, _describe), do: :ok

  defp fail_on(results, title, describe),
    do: flunk("#{length(results)} #{title}:\n\n" <> Enum.map_join(results, "\n", &"  #{&1.name}: #{describe.(&1)}"))

  # Level 1 evaluates, so its reasons are not wrapped in `{:unsupported, _}` like the ones of a decision
  defp uncategorised?(%{level: :expressions}, %{library: {:unsupported, reason}}),
    do: Reason.category({:unsupported, reason}) == :other

  defp uncategorised?(_collector, %{library: {:unsupported, reason}}), do: Reason.category(reason) == :other
  defp uncategorised?(_collector, _result), do: false

  ## The decision table of the unit tests against Postgres

  defp expected(%{meta: meta}), do: meta |> Map.get(:table, %{}) |> Map.get(meta[:key])

  # What Postgres said has to be consistent with what the unit tests expect of a decision. A
  # decision has to be what Postgres returned. A fallback because something raises is right if
  # Postgres raised that, and conservative if it returned a value, as the library cannot know that
  # it does not reach what raises. Neither fails the test, only a decision that is not what
  # Postgres returned.
  defp table_verdict(result) do
    case {expected(result), result.postgres} do
      {nil, _postgres} -> :not_checked
      {decision, postgres} when decision in [:allow, :deny] -> verdict(postgres == {:ok, decision == :allow})
      {{:fallback, {:unsupported, {:raises, code, _}}}, {:error, _sqlstate, code, _message}} -> :agrees
      {{:fallback, {:unsupported, {:raises, _code, _}}}, {:error, _sqlstate, _other, _message}} -> :disagrees
      {{:fallback, {:unsupported, {:raises, _code, _}}}, {:ok, _value}} -> :conservative
      {{:fallback, _reason}, _postgres} -> :not_checked
    end
  end

  defp verdict(true), do: :agrees
  defp verdict(false), do: :disagrees

  ## Report

  defp report(collector, results) do
    by_personal_teams = Enum.group_by(results, & &1.meta[:personal_teams])

    Enum.join(
      [
        "",
        "== sql_logex differential report ==",
        "",
        Differential.report(results, @titles[collector.level]),
        grid_section(Map.get(by_personal_teams, :grid, [])),
        table_section(Map.get(by_personal_teams, :table, [])),
        planner_section(Map.get(by_personal_teams, :planner, []))
      ],
      "\n"
    )
  end

  defp grid_section([]), do: ""

  defp grid_section(results) do
    scenarios = Enum.group_by(results, & &1.meta.scenario)
    decided = Enum.filter(results, &decided?/1)
    fallbacks = Enum.reject(results, &decided?/1)
    scenario_states = Enum.frequencies_by(scenarios, fn {_name, decisions} -> scenario_state(decisions) end)

    by_role =
      results
      |> Enum.group_by(& &1.meta.role)
      |> Enum.sort()
      |> Enum.map(fn {role, in_role} ->
        "    #{role}: #{decided_share(in_role)}, scenarios #{scenario_shares(in_role)}"
      end)

    member = Enum.filter(results, &(&1.meta.role == "member"))

    by_meta = fn key ->
      member
      |> Enum.group_by(& &1.meta[key])
      |> Enum.sort()
      |> Enum.map_join("\n", fn {label, in_label} -> "      #{label}: #{decided_share(in_label)}" end)
    end

    valid_user_id = Enum.filter(member, &(&1.meta.user_id_kind == :valid_uuid))
    valid_or_missing_user_id = Enum.filter(member, &(&1.meta.user_id_kind in [:valid_uuid, :missing]))

    """
    Personal teams, the grid (teams x user ids x roles, plain and initplan, both app.user_id() bodies), the evaluator by default
      scenarios:  #{map_size(scenarios)}   fully decided #{scenario_states[:decided] || 0} (#{percent(scenario_states[:decided] || 0, map_size(scenarios))}), partly decided #{scenario_states[:partly_decided] || 0}, fully fell back #{scenario_states[:fell_back] || 0}
      decisions:  #{length(results)}   decided #{length(decided)} (#{percent(length(decided), length(results))}), fell back #{length(fallbacks)} (#{percent(length(fallbacks), length(results))})
      member with a valid user id (a spelling of a uuid), #{decided_share(valid_user_id)}
        and an ASCII team, #{decided_share(Enum.filter(valid_user_id, & &1.meta.ascii_team))}
      member with a valid or a missing user id, #{decided_share(valid_or_missing_user_id)}
      by role:
    #{Enum.join(by_role, "\n")}
      member, by user id:
    #{by_meta.(:user_id)}
      member, by team:
    #{by_meta.(:team)}
      fallback reasons:
    #{reason_lines(fallbacks)}
    """
  end

  defp decided?(result), do: match?({:value, _}, result.library)

  defp scenario_state(decisions) do
    case Enum.count(decisions, &decided?/1) do
      0 -> :fell_back
      n when n == length(decisions) -> :decided
      _ -> :partly_decided
    end
  end

  defp decided_share(results) do
    decided = Enum.count(results, &decided?/1)
    "#{decided} of #{length(results)} decisions decided (#{percent(decided, length(results))})"
  end

  defp scenario_shares(results) do
    states =
      results
      |> Enum.group_by(& &1.meta.scenario)
      |> Enum.frequencies_by(fn {_name, decisions} -> scenario_state(decisions) end)

    total = Enum.sum(Map.values(states))
    decided = states[:decided] || 0

    "#{decided} of #{total} fully decided (#{percent(decided, total)}), #{states[:partly_decided] || 0} partly, #{states[:fell_back] || 0} fell back"
  end

  defp reason_lines(fallbacks) do
    fallbacks
    |> Enum.frequencies_by(&reason_key(&1.library))
    |> Enum.sort_by(fn {key, count} -> {-count, key} end)
    |> Enum.take(25)
    |> Enum.map_join("\n", fn {key, count} -> "    #{String.pad_leading(Integer.to_string(count), 5)}  #{key}" end)
  end

  defp reason_key({:unsupported, reason}), do: reason_key(reason)
  defp reason_key({:raises, code, _detail}), do: "raises #{code}"
  defp reason_key(reason), do: inspect(reason, limit: 6, printable_limit: 60)

  # Postgres against the library, for the cases the unit tests say depend on the order of the planner
  defp planner_section([]), do: ""

  defp planner_section(results) do
    lines =
      results
      |> Enum.filter(&(&1.meta.flavor == :simple))
      |> Enum.sort_by(&{&1.meta.team, &1.meta.policies, &1.meta.key})
      |> Enum.map_join("\n", fn %{meta: %{key: {operation, kind}}} = result ->
        "    team #{result.meta.team}, #{result.meta.policies} policies, #{operation} #{kind}: postgres #{inspect(result.postgres)}; library #{inspect(result.library, limit: 12)}"
      end)

    """
    Personal teams, planner order: user id user_2abc, kinds outside the list (simple app.user_id())
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
        "    #{result.name}: expected #{inspect(expected(result))}, postgres #{inspect(result.postgres)}"
      end)

    """
    Personal teams, the decision table of the unit tests: #{length(results)} decisions, #{verdicts[:agrees] || 0} agree with Postgres, #{verdicts[:disagrees] || 0} disagree, #{verdicts[:conservative] || 0} are a fallback where Postgres returned a value, #{verdicts[:not_checked] || 0} not checkable (a fallback of the library)
      the fallbacks where Postgres returned a value, because the library can't know the part that raises isn't reached:
    #{conservative_rows}
    """
  end

  defp percent(_part, 0), do: "n/a"
  defp percent(part, whole), do: "#{Float.round(part * 100 / whole, 1)}%"
end
