defmodule SqlLogex.Test.Differential do
  @moduledoc """
  The comparison of the differential tests. Every case runs through Postgres and through the
  library, and the two answers are compared. Postgres is the oracle.

  Every case ends up in one class:

      match      the same value
      fallback   the library said unsupported. That is fine, because the caller then asks Postgres. Counted, see the report
      mismatch   a different value, or a value where Postgres raised an error. Fails the test
      crash      the library raised an exception. Fails the test

  A case of Level 1 compares the value of one expression. A case of Level 2 compares one
  decision of `SqlLogex.decide/3`. With `SQL_LOGEX_REPORT=1`, the module prints a coverage
  report when it is done.

  Realtime's `test/realtime/tenants/sql_logex_differential_test.exs` uses this module too.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  alias SqlLogex.Reason

  @classes [:match, :fallback, :mismatch, :crash]

  @doc """
  Starts the collector of the results of a test module. Call it from `setup_all`. When the module
  is done, it prints the report if `SQL_LOGEX_REPORT=1`. `oracle` names what decides in Postgres,
  for the title of Level 2.
  """
  @spec start_collector(String.t()) :: pid()
  def start_collector(oracle) do
    {:ok, collector} = Agent.start(fn -> [] end)

    ExUnit.Callbacks.on_exit(fn ->
      results = Agent.get(collector, & &1)
      Agent.stop(collector)
      if System.get_env("SQL_LOGEX_REPORT") == "1", do: IO.puts(report(results, oracle))
    end)

    collector
  end

  @doc "Records the results for the report, and fails with every case that is not as it must be."
  @spec finish(pid(), [map()]) :: :ok
  def finish(collector, results) do
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

  @doc """
  The result of a case. `pg` is `{:ok, value}` or `{:error, sqlstate, code, message}`, and `ex`,
  the answer of the library, is `{:value, value}`, `{:unsupported, reason}` or `{:crash, reason}`.
  """
  @spec result(1 | 2, String.t() | atom(), String.t(), tuple(), tuple(), String.t(), map()) :: map()
  def result(level, group, name, pg, ex, detail, extra) do
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

  @doc "`SqlLogex.decide/3`, as the answer of a case: `{:value, allowed?}`, `{:unsupported, reason}` or `{:crash, reason}`."
  @spec decide(SqlLogex.Snapshot.t(), SqlLogex.Env.t(), :read | :write) :: tuple()
  def decide(snapshot, env, operation) do
    case SqlLogex.decide(snapshot, env, operation) do
      decision when decision in [:allow, :deny] ->
        {:value, decision == :allow}

      {:fallback, {:exception, _module} = reason} ->
        {:crash, reason}

      {:fallback, reason} ->
        {:unsupported, reason}
    end
  rescue
    exception -> {:crash, Exception.format(:error, exception, __STACKTRACE__)}
  end

  @doc "The answer of Postgres as the failure output prints it."
  @spec format_postgres(tuple()) :: String.t()
  def format_postgres({:ok, value}), do: "returned #{inspect(value)}"
  def format_postgres({:error, code, name, message}), do: "raised #{code} #{name}: #{message}"

  # What a case has to show. The library can match or fall back, never differ and never crash. And
  # what the unit tests expect of a decision has to be consistent with Postgres. Every reason it
  # falls back with has a category, so a new reason cannot be added without one.
  defp failure?(result),
    do: result.class in [:mismatch, :crash] or table_verdict(result) == :disagrees or uncategorised?(result)

  # Level 1 evaluates, so its reasons are not wrapped in `{:unsupported, _}` like the ones of a decision
  defp uncategorised?(%{ex: {:unsupported, reason}, level: 1}), do: Reason.category({:unsupported, reason}) == :other
  defp uncategorised?(%{ex: {:unsupported, reason}}), do: Reason.category(reason) == :other
  defp uncategorised?(_result), do: false

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

  defp format_evaluator({:value, value}), do: inspect(value)
  defp format_evaluator({:unsupported, reason}), do: "unsupported #{inspect(reason, limit: 12, printable_limit: 200)}"
  defp format_evaluator({:crash, reason}), do: "crashed #{inspect(reason, limit: 12, printable_limit: 400)}"

  ## Classifying

  defp classify(_pg, {:crash, _reason}), do: {:crash, nil}
  defp classify({:ok, value}, {:value, value}), do: {:match, nil}
  defp classify({:ok, _value}, {:value, _other}), do: {:mismatch, :postgres_value}
  defp classify({:ok, _value}, {:unsupported, _reason}), do: {:fallback, :postgres_value}
  defp classify({:error, _sqlstate, _code, _message}, {:value, _value}), do: {:mismatch, :postgres_error}

  # Postgres raised, and the library fell back: because it saw the error coming, because it saw
  # another one coming, or for another reason. Only reported
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

  ## The table of the unit tests against Postgres

  # What Postgres said has to be consistent with what the unit tests expect of a decision. A
  # decision has to be what Postgres returned. A fallback because something raises is right if
  # Postgres raised that, and conservative if it returned a value, as the library cannot know that
  # it does not reach what raises. Neither fails the test, only a decision that is not what
  # Postgres returned.
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

  ## Report

  defp report(results, oracle) do
    by_level = Enum.group_by(results, & &1.level)

    [
      "",
      "== sql_logex differential report ==",
      level_section("Level 1, expressions", Map.get(by_level, 1)),
      level_section("Level 2, policy sets through #{oracle}", Map.get(by_level, 2)),
      user_channel_section(Enum.filter(results, &(&1.user_channels == :grid))),
      table_section(Enum.filter(results, &(&1.user_channels == :table))),
      planner_section(Enum.filter(results, &(&1.user_channels == :planner))),
      ""
    ]
    |> Enum.join("\n")
  end

  # Not run in this module
  defp level_section(_title, nil), do: ""

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
  defp reason_key(reason), do: inspect(reason, limit: 6, printable_limit: 60)

  defp user_channel_section([]), do: ""

  defp user_channel_section(results) do
    scenarios = Enum.group_by(results, & &1.scenario)
    decided = Enum.filter(results, &match?({:value, _}, &1.ex))
    fallbacks = Enum.reject(results, &match?({:value, _}, &1.ex))
    scenario_states = Enum.frequencies_by(scenarios, fn {_name, decisions} -> scenario_state(decisions) end)

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

  defp scenario_state(decisions) do
    case Enum.count(decisions, &match?({:value, _}, &1.ex)) do
      0 -> :fell_back
      n when n == length(decisions) -> :decided
      _ -> :partly_decided
    end
  end

  defp decided_share(results) do
    decided = Enum.count(results, &match?({:value, _}, &1.ex))
    "#{decided} of #{length(results)} decisions decided (#{percent(decided, length(results))})"
  end

  defp scenario_shares(results) do
    states =
      results
      |> Enum.group_by(& &1.scenario)
      |> Enum.frequencies_by(fn {_name, decisions} -> scenario_state(decisions) end)

    total = Enum.sum(Map.values(states))
    decided = states[:decided] || 0

    "#{decided} of #{total} fully decided (#{percent(decided, total)}), #{states[:partly_decided] || 0} partly, #{states[:fell_back] || 0} fell back"
  end

  # Postgres against the library, for the cases the unit tests say depend on the order of the planner
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
end
