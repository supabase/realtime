defmodule Rollcall.Tracker.CommittedChangesTest do
  use ExUnit.Case, async: true

  alias Rollcall.Tracker.CommittedChanges

  defp sorted(diffs) do
    Map.new(diffs, fn {partition, {joins, leaves}} -> {partition, {Enum.sort(joins), Enum.sort(leaves)}} end)
  end

  # The joins and the leaves are both partitioned entries. A leave carries the
  # key and the meta that the view held when the change was committed.
  describe "partition_diffs/1" do
    test "returns one diff for each partition with the joins and the leaves of that partition" do
      committed = %CommittedChanges{
        joins: [{"p1", "a", "k1", %{n: 1}}, {"p2", "b", "k2", %{}}, {"p1", "c", "k3", %{}}],
        leaves: [{"p1", "d", "k4", %{n: 2}}, {"p3", "e", "k5", %{}}]
      }

      assert sorted(CommittedChanges.partition_diffs(committed)) == %{
               "p1" => {[{"a", "k1", %{n: 1}}, {"c", "k3", %{}}], [{"d", "k4", %{n: 2}}]},
               "p2" => {[{"b", "k2", %{}}], []},
               "p3" => {[], [{"e", "k5", %{}}]}
             }
    end

    test "returns no diff when there is no change" do
      assert CommittedChanges.partition_diffs(%CommittedChanges{joins: [], leaves: []}) == %{}
    end
  end
end
