defmodule Rollcall.Tracker.ChangesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Rollcall.Tracker.Changes

  # The model holds the live entries. An operation makes the changes that one
  # tracker operation makes: a join, a leave, a replace, which is a leave and a
  # join in one change, or the leaves of every entry. The model updates the live
  # entries from the operation and merges the changes into the pending changes.
  #
  # At a send, the pending changes must be the net change since the last send.
  # The joins are the entries that are live now and were not live at the last
  # send. The leaves are the entries that were live at the last send and are not
  # live now. An entry that joined and left in the period is in neither list.
  # Each ref is new, so no ref is both a join and a leave.
  #
  # The joins are compared as whole entries: the partition, the ref, the key and
  # the meta. The leaves are compared as ids: the partition and the ref.

  property "the merged changes are the net change since the last send" do
    check all(ops <- list_of(operation(), max_length: 40), max_runs: 1000) do
      Enum.reduce(ops ++ [:send], initial(), &step/2)
    end
  end

  defp operation do
    frequency([
      {6, constant(:join)},
      {3, tuple({constant(:leave), integer(0..9)})},
      {3, tuple({constant(:replace), integer(0..9)})},
      {1, constant(:leave_all)},
      {4, constant(:send)}
    ])
  end

  defp initial do
    %{live: [], base: MapSet.new(), pending: Changes.new(), counter: 0}
  end

  defp step(:join, state) do
    {entry, state} = new_entry(state)
    change(state, Changes.join(Changes.new(), entry), [], [entry])
  end

  defp step({:leave, index}, state) do
    case pick(state, index) do
      nil -> state
      entry -> change(state, Changes.leave(Changes.new(), id(entry)), [entry], [])
    end
  end

  defp step({:replace, index}, state) do
    case pick(state, index) do
      nil ->
        state

      old ->
        {new, state} = new_entry(state)
        changes = Changes.new() |> Changes.leave(id(old)) |> Changes.join(new)
        change(state, changes, [old], [new])
    end
  end

  defp step(:leave_all, state) do
    changes = Enum.reduce(state.live, Changes.new(), &Changes.leave(&2, id(&1)))
    change(state, changes, state.live, [])
  end

  defp step(:send, state) do
    current = MapSet.new(state.live, &id/1)
    joined = state.live |> Enum.reject(&MapSet.member?(state.base, id(&1))) |> Enum.sort()
    left = state.base |> MapSet.difference(current) |> Enum.sort()

    assert state.pending |> Changes.joins() |> Enum.sort() == joined
    assert state.pending |> Changes.leaves() |> Enum.sort() == left

    %{state | base: current, pending: Changes.new()}
  end

  # `left` and `joined` hold the entries that `changes` removes and adds. The
  # model updates the live entries from them, not from `changes`.
  defp change(state, changes, left, joined) do
    %{state | live: (state.live -- left) ++ joined, pending: Changes.merge(state.pending, changes)}
  end

  defp id({partition, ref, _key, _meta}), do: {partition, ref}

  defp pick(%{live: []}, _index), do: nil
  defp pick(%{live: live}, index), do: Enum.at(live, rem(index, length(live)))

  # The key and the meta differ for each entry, so a change that swaps or drops
  # them is visible once the test compares whole entries.
  defp new_entry(%{counter: counter} = state) do
    entry = {"partition_#{rem(counter, 2)}", "ref-#{counter}", "key-#{counter}", %{n: counter}}
    {entry, %{state | counter: counter + 1}}
  end
end
