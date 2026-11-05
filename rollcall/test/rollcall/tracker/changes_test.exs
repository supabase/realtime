defmodule Rollcall.Tracker.ChangesTest do
  use ExUnit.Case, async: true

  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.Entry

  defp entry(partition, key, ref, meta \\ %{}), do: Entry.new(self(), partition, key, meta, ref)

  defp sorted(diffs) do
    diffs
    |> Enum.map(fn {partition, {:diff, joins, leaves}} -> {partition, {:diff, Enum.sort(joins), Enum.sort(leaves)}} end)
    |> Enum.sort()
  end

  describe "partition_diffs/1" do
    test "returns one diff for each partition with the joins and the leaves of that partition" do
      changes =
        Changes.new(
          [entry("p1", "k1", "a", %{n: 1}), entry("p2", "k2", "b"), entry("p1", "k3", "c")],
          [entry("p1", "k4", "d", %{n: 2}), entry("p3", "k5", "e")]
        )

      assert sorted(Changes.partition_diffs(changes)) == [
               {"p1", {:diff, [{"a", "k1", %{n: 1}}, {"c", "k3", %{}}], [{"d", "k4", %{n: 2}}]}},
               {"p2", {:diff, [{"b", "k2", %{}}], []}},
               {"p3", {:diff, [], [{"e", "k5", %{}}]}}
             ]
    end

    test "returns no diff when there is no change" do
      assert Changes.partition_diffs(Changes.new()) == []
    end
  end
end
