defmodule Rollcall.Tracker.ViewTest do
  use ExUnit.Case, async: true

  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.CommittedChanges
  alias Rollcall.Tracker.View

  setup do
    {:ok, table: View.new()}
  end

  # A join is a partitioned entry. A leave is the id of an entry.
  defp partitioned_entry(partition, key, ref, meta \\ %{}), do: {partition, ref, key, meta}

  defp id({partition, ref, _key, _meta}), do: {partition, ref}

  defp joins(entries), do: Changes.new(entries, [])
  defp leaves(entries), do: Changes.new([], Enum.map(entries, &id/1))

  describe "write/2 and entries/2" do
    test "a join appears in the entries of its partition", %{table: table} do
      View.write(table, joins([partitioned_entry("p1", "key", "ref", %{a: 1})]))

      assert View.entries(table, "p1") == [{"ref", "key", %{a: 1}}]
    end

    test "entries/2 returns only the entries of the partition", %{table: table} do
      View.write(
        table,
        joins([
          partitioned_entry("p1", "k1", "a"),
          partitioned_entry("p10", "k2", "b"),
          partitioned_entry("p1", "k3", "c")
        ])
      )

      assert Enum.sort(View.entries(table, "p1")) == [{"a", "k1", %{}}, {"c", "k3", %{}}]
      assert View.entries(table, "p10") == [{"b", "k2", %{}}]
      assert View.entries(table, "p2") == []
    end

    test "a leave removes the entry", %{table: table} do
      old = partitioned_entry("p1", "key", "a")
      View.write(table, joins([old, partitioned_entry("p1", "other", "b")]))

      View.write(table, leaves([old]))

      assert View.entries(table, "p1") == [{"b", "other", %{}}]
    end

    test "a change with a leave and a join replaces the entry", %{table: table} do
      old = partitioned_entry("p1", "key", "a", %{n: 1})
      View.write(table, joins([old]))

      View.write(table, Changes.new([partitioned_entry("p1", "key", "b", %{n: 2})], [id(old)]))

      assert View.entries(table, "p1") == [{"b", "key", %{n: 2}}]
    end
  end

  describe "entries/1" do
    test "returns every entry with its partition", %{table: table} do
      View.write(table, joins([partitioned_entry("p1", "k1", "a"), partitioned_entry("p2", "k2", "b", %{n: 1})]))

      assert Enum.sort(View.entries(table)) == [{"p1", "a", "k1", %{}}, {"p2", "b", "k2", %{n: 1}}]
    end
  end

  # The tracker publishes the leaves with their key and meta. The view deletes
  # them in the same call, so the return value is the only place that has them.
  describe "write/2 return value" do
    test "returns the joins and the entries that left with their key and meta", %{table: table} do
      old = partitioned_entry("p1", "k1", "a", %{n: 1})
      other = partitioned_entry("p2", "k2", "b", %{n: 2})
      kept = partitioned_entry("p1", "k3", "c", %{n: 3})
      View.write(table, joins([old, other, kept]))
      new = partitioned_entry("p1", "k1", "d", %{n: 4})

      assert %CommittedChanges{joins: [^new], leaves: left} =
               View.write(table, Changes.new([new], [id(old), id(other)]))

      assert Enum.sort(left) == [old, other]
    end

    test "raises when a leave has no entry", %{table: table} do
      View.write(table, joins([partitioned_entry("p1", "k1", "a")]))

      assert catch_error(View.write(table, Changes.new([], [{"p1", "missing"}])))
    end
  end

  describe "a table that does not exist" do
    test "returns an empty list for both reads", %{table: table} do
      true = :ets.delete(table)

      assert View.entries(table, "p1") == []
      assert View.entries(table) == []
    end
  end
end
