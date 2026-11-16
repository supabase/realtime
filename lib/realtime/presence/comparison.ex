defmodule Realtime.Presence.Comparison do
  @moduledoc """
  Compares the presence views of Phoenix and Rollcall for a tenant in shadow mode.
  """

  @typedoc "A topic of a tenant."
  @type topic :: String.t()

  @typedoc "The refs that a view holds, by topic."
  @type refs :: %{topic() => [Rollcall.ref()]}

  @typedoc "`:missing`: Phoenix holds the ref and Rollcall does not. `:ghost`: Rollcall holds the ref and Phoenix does not."
  @type kind :: :missing | :ghost

  @typedoc "A ref that one view holds and the other view does not."
  @type candidate :: {topic(), Rollcall.ref(), kind()}

  @type outcome :: :open | :converged | :gone

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
