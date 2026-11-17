defmodule Rollcall.Tracker.ViewTest do
  use ExUnit.Case, async: true

  alias Rollcall.Tracker.Changes
  alias Rollcall.Tracker.Entry
  alias Rollcall.Tracker.View

  setup do
    {:ok, table: View.new()}
  end

  defp entry(partition, key, ref, meta \\ %{}), do: Entry.new(self(), partition, key, meta, ref)

  defp joins(entries), do: Changes.new(entries, [])
  defp leaves(entries), do: Changes.new([], entries)

  describe "write/2 and entries/2" do
    test "a join appears in the entries of its partition", %{table: table} do
      :ok = View.write(table, joins([entry("p1", "key", "ref", %{a: 1})]))

      assert View.entries(table, "p1") == [{"ref", "key", %{a: 1}}]
    end

    test "entries/2 returns only the entries of the partition", %{table: table} do
      :ok =
        View.write(
          table,
          joins([entry("p1", "k1", "a"), entry("p10", "k2", "b"), entry("p1", "k3", "c")])
        )

      assert Enum.sort(View.entries(table, "p1")) == [{"a", "k1", %{}}, {"c", "k3", %{}}]
      assert View.entries(table, "p10") == [{"b", "k2", %{}}]
      assert View.entries(table, "p2") == []
    end

    test "a leave removes the entry", %{table: table} do
      old = entry("p1", "key", "a")
      :ok = View.write(table, joins([old, entry("p1", "other", "b")]))

      :ok = View.write(table, leaves([old]))

      assert View.entries(table, "p1") == [{"b", "other", %{}}]
    end

    test "a change with a leave and a join replaces the entry", %{table: table} do
      old = entry("p1", "key", "a", %{n: 1})
      :ok = View.write(table, joins([old]))

      :ok = View.write(table, Changes.new([entry("p1", "key", "b", %{n: 2})], [old]))

      assert View.entries(table, "p1") == [{"b", "key", %{n: 2}}]
    end
  end

  describe "entries/1" do
    test "returns every entry with its partition", %{table: table} do
      :ok = View.write(table, joins([entry("p1", "k1", "a"), entry("p2", "k2", "b", %{n: 1})]))

      assert Enum.sort(View.entries(table)) == [{"p1", "a", "k1", %{}}, {"p2", "b", "k2", %{n: 1}}]
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
