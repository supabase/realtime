defmodule Realtime.Presence.Comparison do
  @moduledoc """
  Compares the presence views of Phoenix and Rollcall for a tenant in shadow mode.
  """

  alias Realtime.Presence.Comparison.PhoenixReader

  @default_rungs [1_000, 3_000, 5_000, 10_000, 15_000]
  @default_persistent_rung 10_000
  @event [:realtime, :presence, :compare]

  @typedoc "A topic of a tenant."
  @type topic :: String.t()

  @typedoc "The refs that a view holds, by topic."
  @type refs :: %{topic() => [Rollcall.ref()]}

  @typedoc "`:missing`: Phoenix holds the ref and Rollcall does not. `:ghost`: Rollcall holds the ref and Phoenix does not."
  @type kind :: :missing | :ghost

  @typedoc "A ref that one view holds and the other view does not."
  @type candidate :: {topic(), Rollcall.ref(), kind()}

  @type outcome :: :open | :converged | :gone

  @typedoc """
  A rung of the ladder: the delay of a check after the first read. The functions of this module
  use a rung as a label. They do not read the clock.
  """
  @type rung :: pos_integer()

  @typedoc "The counts of the candidates of one kind that were checked at one rung."
  @type rung_row :: %{
          rung: rung(),
          kind: kind(),
          open: non_neg_integer(),
          converged: non_neg_integer(),
          gone: non_neg_integer()
        }

  @typedoc """
  The state of one comparison. `open` is the list of the candidates that no check has closed.
  `rungs` is the list of the rows of the checks so far.
  """
  @type t :: %{
          open: [candidate()],
          rungs: [rung_row()],
          persistent: [candidate()],
          persistent_rung: rung(),
          entries: non_neg_integer(),
          candidates: %{kind() => non_neg_integer()}
        }

  @typedoc """
  The result of a comparison.

    * `outcome`: `:clean` when the views had no candidate. `:persistent` when a candidate was
      open after the persistent rung. `:transient` in all other cases.
    * `entries`: the number of refs in the union of the two views at the first read.
    * `candidates`: the number of candidates at the first read, by kind.
    * `persistent`: the candidates that were open after the persistent rung.
    * `rungs`: the rows of all the checks.
  """
  @type summary :: %{
          outcome: :clean | :transient | :persistent,
          entries: non_neg_integer(),
          candidates: %{kind() => non_neg_integer()},
          persistent: [candidate()],
          rungs: [rung_row()]
        }

  @doc """
  Compares the views of `tenant` in Phoenix and in Rollcall, and returns the result.

  Reads both views, then checks the open candidates at each rung. The function sleeps until the
  rung is due, measured from the first read. It stops when no candidate is open or after the last
  rung. 

  Returns `:discarded` when the Rollcall tracker of `tenant` does not run after a read. An absent
  tracker reads as an empty view, so the result would show every Phoenix ref as `:missing`.

  Options:

    * `:phoenix` - the Phoenix tracker module. The default is `RealtimeWeb.Presence`.
    * `:rollcall` - the name of the Rollcall instance. The default is `Realtime.Presence.Rollcall`.
    * `:rungs` - the rungs in milliseconds, in ascending order. The default is
      `[1_000, 3_000, 5_000, 10_000, 15_000]`.
    * `:persistent_rung` - the rung for `start/3`. The default is `10_000`.
    * `:sleep` - a function that waits. `run/2` calls it with the milliseconds until the next
      rung is due, before each rung. The default is `Process.sleep/1`.
  """
  @spec run(String.t(),
          phoenix: module(),
          rollcall: Rollcall.name(),
          rungs: [rung()],
          persistent_rung: rung(),
          sleep: (non_neg_integer() -> any())
        ) :: {:ok, summary()} | :discarded
  def run(tenant, opts \\ []) do
    phoenix = Keyword.get(opts, :phoenix, RealtimeWeb.Presence)
    rollcall = Keyword.get(opts, :rollcall, Realtime.Presence.Rollcall)
    rungs = Keyword.get(opts, :rungs, @default_rungs)
    persistent_rung = Keyword.get(opts, :persistent_rung, @default_persistent_rung)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)

    initial_phoenix_view = PhoenixReader.tenant_refs(phoenix, tenant)
    initial_rollcall_view = Rollcall.refs(rollcall, tenant)

    if is_pid(Rollcall.Tracker.whereis(rollcall, tenant)) do
      t0 = System.monotonic_time(:millisecond)

      state = start(initial_phoenix_view, initial_rollcall_view, persistent_rung)

      do_run(state, tenant, phoenix, rollcall, rungs, sleep, t0)
    else
      :discarded
    end
  end

  defp do_run(%{open: []} = state, _tenant, _phoenix, _rollcall, _rungs, _sleep, _t0), do: {:ok, summarize(state)}

  defp do_run(state, _tenant, _phoenix, _rollcall, [], _sleep, _t0), do: {:ok, summarize(state)}

  defp do_run(state, tenant, phoenix, rollcall, [rung | rungs], sleep, t0) do
    sleep.(max(t0 + rung - System.monotonic_time(:millisecond), 0))

    topics = open_topics(state)
    phoenix_refs = Map.new(topics, &{&1, PhoenixReader.topic_refs(phoenix, &1)})
    rollcall_refs = Map.new(topics, &{&1, Rollcall.refs(rollcall, tenant, &1)})

    if is_pid(Rollcall.Tracker.whereis(rollcall, tenant)) do
      state = advance(state, rung, phoenix_refs, rollcall_refs)

      do_run(state, tenant, phoenix, rollcall, rungs, sleep, t0)
    else
      :discarded
    end
  end

  @doc """
  Starts a comparison from the first reads of both views.

  The candidates are the result of `diff/2` for `phoenix` and `rollcall`. `persistent_rung` is the
  rung that decides if a candidate is persistent. The state counts `entries` and the candidates
  by kind at this point.
  """
  @spec start(refs(), refs(), rung()) :: t()
  def start(phoenix, rollcall, persistent_rung) do
    open_candidates = diff(phoenix, rollcall)

    candidates =
      open_candidates
      |> Enum.frequencies_by(fn {_topic, _ref, kind} -> kind end)

    candidates = Map.merge(%{missing: 0, ghost: 0}, candidates)

    entry_count =
      phoenix
      |> Enum.reduce(Map.get(candidates, :ghost, 0), fn
        {_topic, refs}, acc -> Enum.count(refs) + acc
      end)

    %{
      open: open_candidates,
      persistent_rung: persistent_rung,
      persistent: [],
      rungs: [],
      entries: entry_count,
      candidates: candidates
    }
  end

  @doc """
  Returns the topics of the open candidates of `state`, each topic once.

  Read only these topics to get the views for `advance/4`.
  """
  @spec open_topics(t()) :: [topic()]
  def open_topics(state) do
    state.open
    |> Enum.map(fn {topic, _ref, _kind} -> topic end)
    |> Enum.uniq()
  end

  @doc """
  Checks the open candidates of `state` at `rung` and returns the new state.

  `phoenix` and `rollcall` hold the fresh refs of the topics from `open_topics/1`. The outcome of
  each open candidate comes from `step/3`.

    * An `:open` candidate stays in `open`.
    * A `:converged` or `:gone` candidate leaves `open`. No later check reads it.
    * `rungs` gets one row for each kind that had an open candidate at this rung.
    * When `rung` is the persistent rung, the candidates that are still open are persistent.
      A later check does not change this list.
  """
  @spec advance(t(), rung(), refs(), refs()) :: t()
  def advance(state, rung, phoenix, rollcall) do
    {state, rung_outcomes} =
      state.open
      |> step(phoenix, rollcall)
      |> Enum.reduce(
        {%{state | open: []}, %{}},
        fn {{_topic, _ref, kind} = candidate, outcome}, {state, rung_outcomes} ->
          {
            case outcome do
              :open -> %{state | open: [candidate | state.open]}
              :converged -> state
              :gone -> state
            end,
            increment_rung_outcome(rung_outcomes, kind, outcome)
          }
        end
      )

    %{
      state
      | rungs:
          Enum.concat(
            state.rungs,
            Enum.map(rung_outcomes, fn {kind, outcome} ->
              Map.merge(%{rung: rung, kind: kind, gone: 0, converged: 0, open: 0}, outcome)
            end)
          ),
        persistent:
          if rung == state.persistent_rung do
            state.open
          else
            state.persistent
          end
    }
  end

  defp increment_rung_outcome(rung_outcomes, kind, outcome) do
    Map.update(rung_outcomes, kind, Map.put(%{}, outcome, 1), fn outcomes ->
      Map.update(outcomes, outcome, 1, &(&1 + 1))
    end)
  end

  @doc """
  Returns the summary of the comparison in `state`.

  Call it when no candidate is open or after the last rung.
  """
  @spec summarize(t()) :: summary()
  def summarize(state) do
    %{
      outcome: summary_outcome(state),
      candidates: state.candidates,
      persistent: state.persistent,
      rungs: state.rungs,
      entries: state.entries
    }
  end

  defp summary_outcome(state) do
    cond do
      not Enum.empty?(state.persistent) -> :persistent
      state.candidates == %{missing: 0, ghost: 0} -> :clean
      true -> :transient
    end
  end

  @doc """
  Emits the telemetry events of one comparison of `tenant`.

  `result` is the return value of `run/2`. `duration` is the time of the comparison in native time
  units. The events are under `[:realtime, :presence, :compare, ...]`:

    * `:comparison`: once. Measurements: `entries` and `duration`. Metadata: `tenant` and `outcome`.
      A discarded comparison has the outcome `:discarded` and no `entries`, and it emits no other event.
    * `:candidates`: once for each kind, also with a count of 0. Measurement: `count`.
      Metadata: `tenant` and `kind`.
    * `:rung`: once for each row of `rungs`. Measurements: `open`, `converged` and `gone`.
      Metadata: `rung` and `kind`. It has no `tenant`.
    * `:persistent`: once for each kind that has a persistent candidate. Measurement: `count`.
      Metadata: `tenant` and `kind`.
  """
  @spec emit(String.t(), {:ok, summary()} | :discarded, integer()) :: :ok
  def emit(tenant, :discarded, duration) do
    :telemetry.execute(@event ++ [:comparison], %{duration: duration}, %{
      outcome: :discarded,
      tenant: tenant
    })
  end

  def emit(tenant, {:ok, result}, duration) do
    :telemetry.execute(@event ++ [:comparison], %{entries: result.entries, duration: duration}, %{
      outcome: result.outcome,
      tenant: tenant
    })

    Enum.each(result.candidates, fn {kind, count} ->
      :telemetry.execute(@event ++ [:candidates], %{count: count}, %{kind: kind, tenant: tenant})
    end)

    result.persistent
    |> Enum.frequencies_by(fn {_topic, _ref, kind} -> kind end)
    |> Enum.each(fn {kind, count} ->
      :telemetry.execute(@event ++ [:persistent], %{count: count}, %{kind: kind, tenant: tenant})
    end)

    Enum.each(result.rungs, fn rung ->
      :telemetry.execute(
        @event ++ [:rung],
        Map.take(rung, [:open, :converged, :gone]),
        Map.take(rung, [:rung, :kind])
      )
    end)
  end

  @doc """
  Returns the candidates of two views: the refs that one view holds and the other view does not.

  `phoenix` and `rollcall` map each topic to its refs. A ref in `phoenix` only is `:missing`.
  A ref in `rollcall` only is `:ghost`. All the refs of a topic that only one view holds are
  candidates. The order of the result is not defined.
  """
  @spec diff(refs(), refs()) :: [candidate()]
  def diff(phoenix, rollcall) do
    topics = MapSet.new(Enum.concat(Map.keys(phoenix), Map.keys(rollcall)))

    topics
    |> Stream.flat_map(fn topic ->
      phoenix_refs = MapSet.new(Map.get(phoenix, topic, []))
      rollcall_refs = MapSet.new(Map.get(rollcall, topic, []))

      ghosts = MapSet.difference(rollcall_refs, phoenix_refs)
      missings = MapSet.difference(phoenix_refs, rollcall_refs)

      ghost_candidates = ghosts |> Stream.map(fn ghost -> {topic, ghost, :ghost} end)
      missing_candidates = missings |> Stream.map(fn missing -> {topic, missing, :missing} end)

      Stream.concat(ghost_candidates, missing_candidates)
    end)
    |> Enum.to_list()
  end

  @doc """
  Checks each of `candidates` against fresh views, and returns each candidate with its outcome.

    * `:converged`: both views hold the ref now, or only the other view holds it. The kind
      changed, and the original difference ended.
    * `:open`: the view that held the ref still holds it, and the other view does not.
    * `:gone`: neither view holds the ref, or neither view holds the topic.

  The views need only the topics of the candidates. A check adds no new candidate.
  """
  @spec step([candidate()], refs(), refs()) :: [{candidate(), outcome()}]
  def step(candidates, phoenix, rollcall) do
    phoenix = ref_sets(phoenix)
    rollcall = ref_sets(rollcall)

    Enum.map(candidates, fn {topic, ref, kind} = candidate ->
      {candidate, outcome(kind, holds?(phoenix, topic, ref), holds?(rollcall, topic, ref))}
    end)
  end

  defp ref_sets(refs), do: Map.new(refs, fn {topic, refs} -> {topic, MapSet.new(refs)} end)

  defp holds?(ref_sets, topic, ref), do: ref_sets |> Map.get(topic, MapSet.new()) |> MapSet.member?(ref)

  defp outcome(_kind, false, false), do: :gone
  defp outcome(:ghost, false, true), do: :open
  defp outcome(:missing, true, false), do: :open

  # The sweep chooses the divergence that the ladder waits on: this ref, held by one view only. A
  # candidate is open only while that same divergence lasts. A ref that only the other view holds
  # now is a different divergence, so the one that the sweep chose has ended. A check adds no new
  # candidate, so the flip is not followed. The next sweep finds it if it lasts. A flip is rare:
  # refs are unique, so it needs an entry that leaves one view before the other view gets its join.
  defp outcome(:ghost, true, _rollcall), do: :converged
  defp outcome(:missing, _phoenix, true), do: :converged
end
