defmodule Rollcall.Tracker.LocalTest do
  use ExUnit.Case, async: true

  import Rollcall.RefHelpers

  alias Rollcall.Tracker.Local

  describe "new/0" do
    test "returns an empty set" do
      assert Local.empty?(Local.new())
    end
  end

  describe "track/6 with a new key" do
    test "returns the new entry as a join" do
      pid = new_pid()
      ref = unique_ref()

      assert {%{joins: [{"partition", ^ref, "key", %{a: 1}}], leaves: []}, local} =
               Local.track(Local.new(), pid, "partition", "key", %{a: 1}, ref)

      assert [%{ref: ^ref, pid: ^pid}] = Local.entries(local, "partition")
    end

    test "adds the entry to its partition" do
      {entry, local} = track!(Local.new(), new_pid(), "partition", "key")

      assert Local.entries(local, "partition") == [entry]
    end

    test "accepts the same key for another pid" do
      {entry_1, local} = track!(Local.new(), new_pid(), "partition", "key")
      {entry_2, local} = track!(local, new_pid(), "partition", "key")

      assert sorted(Local.entries(local, "partition")) == sorted([entry_1, entry_2])
    end

    test "accepts the same key in another partition" do
      pid = new_pid()
      {entry_1, local} = track!(Local.new(), pid, "partition_1", "key")
      {entry_2, local} = track!(local, pid, "partition_2", "key")

      assert Local.entries(local, "partition_1") == [entry_1]
      assert Local.entries(local, "partition_2") == [entry_2]
    end

    test "accepts another key for the same pid" do
      pid = new_pid()
      {entry_1, local} = track!(Local.new(), pid, "partition", "key_1")
      {entry_2, local} = track!(local, pid, "partition", "key_2")

      assert sorted(Local.entries(local, "partition")) == sorted([entry_1, entry_2])
    end
  end

  describe "track/6 with an existing key" do
    setup do
      pid = new_pid()
      {entry, local} = track!(Local.new(), pid, "partition", "key", %{a: 1})
      %{pid: pid, entry: entry, local: local}
    end

    # The result does not depend on the meta. The second meta is equal to the
    # meta of the existing entry.
    test "returns the id of the old entry as a leave and the new entry as a join", %{
      pid: pid,
      entry: old,
      local: local
    } do
      for meta <- [%{a: 2}, %{a: 1}] do
        ref = unique_ref()
        expected_meta = Map.put(meta, :rc_prev_ref, old.ref)
        old_key = {"partition", old.ref}

        assert {%{joins: [{"partition", ^ref, "key", ^expected_meta}], leaves: [^old_key]}, local} =
                 Local.track(local, pid, "partition", "key", meta, ref)

        assert [%{ref: ^ref, pid: ^pid}] = Local.entries(local, "partition")
      end
    end

    test "overwrites :rc_prev_ref in the meta of the caller", %{pid: pid, entry: old, local: local} do
      meta = %{a: 2, rc_prev_ref: "from-the-caller"}

      {%{joins: [{_partition, _ref, _key, new_meta}]}, _local} =
        Local.track(local, pid, "partition", "key", meta, unique_ref())

      assert new_meta.rc_prev_ref == old.ref
    end

    test "replaces the entry", %{pid: pid, local: local} do
      ref = unique_ref()

      {_changes, local} = Local.track(local, pid, "partition", "key", %{a: 2}, ref)

      assert [%{ref: ^ref}] = Local.entries(local, "partition")
    end

    test "keeps the entry of another pid for the same key", %{pid: pid, local: local} do
      {other, local} = track!(local, new_pid(), "partition", "key", %{a: 1})
      ref = unique_ref()

      {_changes, local} = Local.track(local, pid, "partition", "key", %{a: 2}, ref)

      assert local |> Local.entries("partition") |> Enum.map(& &1.ref) |> Enum.sort() ==
               Enum.sort([other.ref, ref])
    end
  end

  describe "entries/2" do
    test "returns an empty list for a partition with no entry" do
      assert Local.entries(Local.new(), "partition") == []
    end

    test "returns only the entries of the partition" do
      {entry, local} = track!(Local.new(), new_pid(), "partition_1", "key")
      {_other, local} = track!(local, new_pid(), "partition_2", "key")

      assert Local.entries(local, "partition_1") == [entry]
    end
  end

  describe "untrack/4" do
    test "returns the id of the removed entry as a leave" do
      pid = new_pid()
      {entry, local} = track!(Local.new(), pid, "partition", "key")
      leave = {"partition", entry.ref}

      assert {%{joins: [], leaves: [^leave]}, _local} =
               Local.untrack(local, pid, "partition", "key")
    end

    test "removes the entry from its partition" do
      pid = new_pid()
      {_entry, local} = track!(Local.new(), pid, "partition", "key")

      {_changes, local} = Local.untrack(local, pid, "partition", "key")

      assert Local.entries(local, "partition") == []
    end

    test "returns no change and the same set when nothing matches" do
      {_entry, local} = track!(Local.new(), new_pid(), "partition", "key")

      assert {%{joins: [], leaves: []}, ^local} =
               Local.untrack(local, new_pid(), "partition", "key")
    end

    test "keeps the entry of another pid for the same key" do
      pid = new_pid()
      {_entry_1, local} = track!(Local.new(), pid, "partition", "key")
      {entry_2, local} = track!(local, new_pid(), "partition", "key")

      {_changes, local} = Local.untrack(local, pid, "partition", "key")

      assert Local.entries(local, "partition") == [entry_2]
    end

    test "keeps the entry for the same key in another partition" do
      pid = new_pid()
      {_entry_1, local} = track!(Local.new(), pid, "partition_1", "key")
      {entry_2, local} = track!(local, pid, "partition_2", "key")

      {_changes, local} = Local.untrack(local, pid, "partition_1", "key")

      assert Local.entries(local, "partition_2") == [entry_2]
    end

    test "accepts a track for the same key after the untrack" do
      pid = new_pid()
      {_entry, local} = track!(Local.new(), pid, "partition", "key")
      {_changes, local} = Local.untrack(local, pid, "partition", "key")

      assert {%{joins: [_join], leaves: []}, _local} =
               Local.track(local, pid, "partition", "key", %{}, unique_ref())
    end
  end

  describe "untrack_pid/2" do
    test "returns the ids of the entries of the pid in all partitions as leaves" do
      pid = new_pid()
      {entry_1, local} = track!(Local.new(), pid, "partition_1", "key_1")
      {entry_2, local} = track!(local, pid, "partition_2", "key_2")

      {%{joins: [], leaves: leaves}, _local} = Local.untrack_pid(local, pid)

      assert Enum.sort(leaves) == Enum.sort([{"partition_1", entry_1.ref}, {"partition_2", entry_2.ref}])
    end

    test "keeps the entries of other pids" do
      pid = new_pid()
      {_entry_1, local} = track!(Local.new(), pid, "partition", "key_1")
      {entry_2, local} = track!(local, new_pid(), "partition", "key_2")

      {_changes, local} = Local.untrack_pid(local, pid)

      assert Local.entries(local, "partition") == [entry_2]
    end

    test "returns no change and the same set for a pid with no entry" do
      {_entry, local} = track!(Local.new(), new_pid(), "partition", "key")

      assert {%{joins: [], leaves: []}, ^local} = Local.untrack_pid(local, new_pid())
    end
  end

  # After an untrack, the set equals the set that never tracked the entry.
  # The set holds no record of a removed entry, a removed pid or an empty
  # partition.
  describe "untrack leaves no record" do
    test "after the last untrack" do
      pid = new_pid()
      {_entry, local} = track!(Local.new(), pid, "partition", "key")

      {_changes, local} = Local.untrack(local, pid, "partition", "key")

      assert local == Local.new()
    end

    test "after untrack_pid removes the last entries" do
      pid = new_pid()
      {_entry_1, local} = track!(Local.new(), pid, "partition_1", "key_1")
      {_entry_2, local} = track!(local, pid, "partition_2", "key_2")

      {_changes, local} = Local.untrack_pid(local, pid)

      assert local == Local.new()
    end

    test "after a replace and the last untrack" do
      pid = new_pid()
      {_entry, local} = track!(Local.new(), pid, "partition", "key", %{a: 1})
      {_changes, local} = Local.track(local, pid, "partition", "key", %{a: 2}, unique_ref())

      {_changes, local} = Local.untrack(local, pid, "partition", "key")

      assert local == Local.new()
    end

    test "for many pids that each tracked and untracked an entry" do
      local =
        Enum.reduce(1..100, Local.new(), fn n, local ->
          pid = new_pid()
          {_entry, local} = track!(local, pid, "partition_#{n}", "key")
          {_changes, local} = Local.untrack_pid(local, pid)
          local
        end)

      assert local == Local.new()
    end

    test "for an entry that shares a pid and a partition with another entry" do
      pid = new_pid()
      ref = unique_ref()
      {_entry_1, local} = track!(Local.new(), pid, "partition", "key_1")
      {_changes, local} = Local.track(local, pid, "partition", "key_2", %{}, ref)

      {_changes, local} = Local.untrack(local, pid, "partition", "key_1")

      {_changes, expected} = Local.track(Local.new(), pid, "partition", "key_2", %{}, ref)
      assert local == expected
    end

    test "for a pid that shares a partition with another pid" do
      pid_1 = new_pid()
      pid_2 = new_pid()
      ref = unique_ref()
      {_entry, local} = track!(Local.new(), pid_1, "partition", "key")
      {_changes, local} = Local.track(local, pid_2, "partition", "key", %{}, ref)

      {_changes, local} = Local.untrack_pid(local, pid_1)

      {_changes, expected} = Local.track(Local.new(), pid_2, "partition", "key", %{}, ref)
      assert local == expected
    end
  end

  describe "tracks?/2" do
    test "returns false for a pid with no entry" do
      refute Local.tracks?(Local.new(), new_pid())
    end

    test "returns true for a pid with an entry" do
      pid = new_pid()
      {_entry, local} = track!(Local.new(), pid, "partition", "key")

      assert Local.tracks?(local, pid)
    end

    test "returns true while the pid has another entry" do
      pid = new_pid()
      {_entry_1, local} = track!(Local.new(), pid, "partition", "key_1")
      {_entry_2, local} = track!(local, pid, "partition", "key_2")

      {_changes, local} = Local.untrack(local, pid, "partition", "key_1")

      assert Local.tracks?(local, pid)
    end

    test "returns false after the last entry of the pid leaves" do
      pid = new_pid()
      {_entry, local} = track!(Local.new(), pid, "partition", "key")

      {_changes, local} = Local.untrack(local, pid, "partition", "key")

      refute Local.tracks?(local, pid)
    end
  end

  describe "empty?/1" do
    test "returns false when the set has an entry" do
      {_entry, local} = track!(Local.new(), new_pid(), "partition", "key")

      refute Local.empty?(local)
    end

    test "returns true after the last untrack" do
      pid = new_pid()
      {_entry, local} = track!(Local.new(), pid, "partition", "key")

      {_changes, local} = Local.untrack(local, pid, "partition", "key")

      assert Local.empty?(local)
    end

    test "returns true after untrack_pid removes the last entries" do
      pid = new_pid()
      {_entry, local} = track!(Local.new(), pid, "partition", "key")

      {_changes, local} = Local.untrack_pid(local, pid)

      assert Local.empty?(local)
    end
  end

  # A pid that Local never inspects. Each call returns a different pid.
  defp new_pid, do: spawn(fn -> :ok end)

  # Tracks a key that is new to the set and returns the new entry.
  defp track!(local, pid, partition, key, meta \\ %{}) do
    ref = unique_ref()

    {changes, local} = Local.track(local, pid, partition, key, meta, ref)

    assert changes.joins == [{partition, ref, key, meta}]
    assert changes.leaves == []

    [entry] = local |> Local.entries(partition) |> Enum.filter(&(&1.ref == ref))

    {entry, local}
  end

  defp sorted(entries), do: Enum.sort_by(entries, & &1.ref)
end
