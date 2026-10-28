defmodule Rollcall.Tracker.LocalPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Rollcall.Tracker.Local

  # The generators draw from small pools. Operations then hit the same pid,
  # partition and key often. A track often replaces an entry.
  @partitions ["partition_1", "partition_2"]
  @keys ["key_1", "key_2", "key_3"]
  # The second meta is a different meta. A track can repeat the meta of an entry.
  @metas [%{a: 1}, %{a: 2}]
  @pid_count 3

  # The model is a list of {pid, partition, key, meta, ref} tuples. Each
  # operation on the model is a filter and a prepend on that list.

  setup do
    %{pids: for(_ <- 1..@pid_count, do: spawn(fn -> :ok end))}
  end

  property "agrees with a list of entries after any sequence of operations", %{pids: pids} do
    check all(operations <- operation_list()) do
      Enum.reduce(operations, {Local.new(), []}, fn operation, {local, model} ->
        ref = make_ref()
        {changes, local} = apply_to_local(local, pids, operation, ref)
        {expected, model} = apply_to_model(model, pids, operation, ref)

        assert change_tuples(changes) == expected
        assert_agrees(local, model, pids)

        {local, model}
      end)
    end
  end

  property "the changes rebuild the set", %{pids: pids} do
    check all(operations <- operation_list()) do
      Enum.reduce(operations, {Local.new(), MapSet.new()}, fn operation, {local, view} ->
        {changes, local} = apply_to_local(local, pids, operation, make_ref())
        {joins, leaves} = change_tuples(changes)

        view =
          view
          |> MapSet.difference(MapSet.new(leaves))
          |> MapSet.union(MapSet.new(joins))

        assert view == MapSet.new(all_entries(local))

        {local, view}
      end)
    end
  end

  property "untracking every pid returns the empty set", %{pids: pids} do
    check all(operations <- operation_list()) do
      local =
        Enum.reduce(operations, Local.new(), fn operation, local ->
          {_changes, local} = apply_to_local(local, pids, operation, make_ref())
          local
        end)

      local =
        Enum.reduce(pids, local, fn pid, local ->
          {_changes, local} = Local.untrack_pid(local, pid)
          local
        end)

      assert local == Local.new()
    end
  end

  defp operation_list, do: list_of(operation(), max_length: 40)

  defp operation do
    pid_index = integer(0..(@pid_count - 1))
    partition = member_of(@partitions)
    key = member_of(@keys)
    meta = member_of(@metas)

    frequency([
      {5, tuple({constant(:track), pid_index, partition, key, meta})},
      {3, tuple({constant(:untrack), pid_index, partition, key})},
      {1, tuple({constant(:untrack_pid), pid_index})}
    ])
  end

  defp apply_to_local(local, pids, {:track, index, partition, key, meta}, ref) do
    Local.track(local, Enum.at(pids, index), partition, key, meta, ref)
  end

  defp apply_to_local(local, pids, {:untrack, index, partition, key}, _ref) do
    Local.untrack(local, Enum.at(pids, index), partition, key)
  end

  defp apply_to_local(local, pids, {:untrack_pid, index}, _ref) do
    Local.untrack_pid(local, Enum.at(pids, index))
  end

  # Each function returns {{joins, leaves}, model}. The joins and the leaves are
  # sorted lists of tuples.
  defp apply_to_model(model, pids, {:track, index, partition, key, meta}, ref) do
    pid = Enum.at(pids, index)
    {replaced, kept} = Enum.split_with(model, &same_id?(&1, pid, partition, key))
    entry = {pid, partition, key, meta, ref}

    {{[entry], Enum.sort(replaced)}, [entry | kept]}
  end

  defp apply_to_model(model, pids, {:untrack, index, partition, key}, _ref) do
    pid = Enum.at(pids, index)
    {removed, kept} = Enum.split_with(model, &same_id?(&1, pid, partition, key))

    {{[], Enum.sort(removed)}, kept}
  end

  defp apply_to_model(model, pids, {:untrack_pid, index}, _ref) do
    pid = Enum.at(pids, index)
    {removed, kept} = Enum.split_with(model, fn {entry_pid, _, _, _, _} -> entry_pid == pid end)

    {{[], Enum.sort(removed)}, kept}
  end

  defp same_id?({pid, partition, key, _meta, _ref}, pid, partition, key), do: true
  defp same_id?(_entry, _pid, _partition, _key), do: false

  defp assert_agrees(local, model, pids) do
    for partition <- @partitions do
      expected =
        model
        |> Enum.filter(fn {_, entry_partition, _, _, _} -> entry_partition == partition end)
        |> Enum.sort()

      actual = local |> Local.entries(partition) |> Enum.map(&to_tuple/1) |> Enum.sort()

      assert actual == expected
    end

    for pid <- pids do
      assert Local.tracks?(local, pid) ==
               Enum.any?(model, fn {entry_pid, _, _, _, _} -> entry_pid == pid end)
    end

    assert Local.empty?(local) == (model == [])

    # An empty set holds no record of an entry, a pid or a partition.
    if model == [], do: assert(local == Local.new())
  end

  defp all_entries(local) do
    @partitions
    |> Enum.flat_map(&Local.entries(local, &1))
    |> Enum.map(&to_tuple/1)
  end

  defp change_tuples(%{joins: joins, leaves: leaves}) do
    {joins |> Enum.map(&to_tuple/1) |> Enum.sort(), leaves |> Enum.map(&to_tuple/1) |> Enum.sort()}
  end

  defp to_tuple(%{pid: pid, partition: partition, key: key, meta: meta, ref: ref}) do
    {pid, partition, key, meta, ref}
  end
end
