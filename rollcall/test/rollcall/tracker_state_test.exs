defmodule Rollcall.TrackerStateTest do
  use Rollcall.Case, async: true

  alias Rollcall.Tracker
  alias Rollcall.Tracker.Local

  describe "get_state/2" do
    test "returns nil when no tracker runs", %{scope: scope, rollcall: rollcall} do
      assert Tracker.get_state(rollcall, scope) == nil
    end

    test "does not start a tracker", %{scope: scope, rollcall: rollcall} do
      Tracker.get_state(rollcall, scope)

      refute scope in Rollcall.scopes(rollcall)
    end

    test "returns the scope of the tracker", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})

      assert %{scope: ^scope} = Tracker.get_state(rollcall, scope)
    end
  end

  describe "track/6 refs" do
    test "returns different refs for different keys", %{scope: scope, rollcall: rollcall} do
      {:ok, ref_1} = Rollcall.track(rollcall, self(), scope, "partition", "key_1", %{})
      {:ok, ref_2} = Rollcall.track(rollcall, self(), scope, "partition", "key_2", %{})

      refute ref_1 == ref_2
    end

    test "returns different refs when the same key is tracked again", %{scope: scope, rollcall: rollcall} do
      {:ok, ref_1} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{a: 1})
      {:ok, ref_2} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{a: 1})

      refute ref_1 == ref_2
    end

    test "returns different refs for different pids", %{scope: scope, rollcall: rollcall} do
      other = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, ref_1} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
      {:ok, ref_2} = Rollcall.track(rollcall, other, scope, "partition", "key", %{})

      Process.exit(other, :kill)
      refute ref_1 == ref_2
    end

    test "returns different refs in different scopes", %{scope: scope, rollcall: rollcall} do
      {:ok, ref_1} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})
      {:ok, ref_2} = Rollcall.track(rollcall, self(), unique_scope(), "partition", "key", %{})

      refute ref_1 == ref_2
    end
  end

  describe "track/6 local entries" do
    test "stores the entry with the returned ref", %{scope: scope, rollcall: rollcall} do
      pid = self()
      {:ok, ref} = Rollcall.track(rollcall, pid, scope, "partition", "key", %{a: 1})

      assert [%{ref: ^ref, pid: ^pid, partition: "partition", key: "key", meta: %{a: 1}}] =
               local_entries(rollcall, scope, "partition")
    end

    test "replaces the entry when the same key is tracked again", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{a: 1})
      {:ok, ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{a: 2})

      assert [%{ref: ^ref, meta: %{a: 2}}] = local_entries(rollcall, scope, "partition")
    end

    test "keeps the entries of different partitions apart", %{scope: scope, rollcall: rollcall} do
      {:ok, ref_1} = Rollcall.track(rollcall, self(), scope, "partition_1", "key", %{})
      {:ok, ref_2} = Rollcall.track(rollcall, self(), scope, "partition_2", "key", %{})

      assert [%{ref: ^ref_1}] = local_entries(rollcall, scope, "partition_1")
      assert [%{ref: ^ref_2}] = local_entries(rollcall, scope, "partition_2")
    end
  end

  describe "untrack/5 local entries" do
    test "removes the entry", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_1", %{})
      {:ok, ref_2} = Rollcall.track(rollcall, self(), scope, "partition", "key_2", %{})

      :ok = Rollcall.untrack(rollcall, self(), scope, "partition", "key_1")

      assert [%{ref: ^ref_2}] = local_entries(rollcall, scope, "partition")
    end
  end

  describe "version" do
    test "is 1 after the first track", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})

      assert Tracker.get_state(rollcall, scope).version == 1
    end

    test "increments for a track of another key", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_1", %{})
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_2", %{})

      assert Tracker.get_state(rollcall, scope).version == 2
    end

    test "increments once when the same key is tracked again", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{a: 1})
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{a: 2})

      assert Tracker.get_state(rollcall, scope).version == 2
    end

    test "increments when the same key is tracked again with the same meta", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{a: 1})
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{a: 1})

      assert Tracker.get_state(rollcall, scope).version == 2
    end

    test "increments for an untrack that removes an entry", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_1", %{})
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_2", %{})

      :ok = Rollcall.untrack(rollcall, self(), scope, "partition", "key_1")

      assert Tracker.get_state(rollcall, scope).version == 3
    end

    test "does not change for an untrack that removes nothing", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})

      :ok = Rollcall.untrack(rollcall, self(), scope, "partition", "other_key")

      assert Tracker.get_state(rollcall, scope).version == 1
    end
  end

  describe "incarnation" do
    test "is an integer", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key", %{})

      assert is_integer(Tracker.get_state(rollcall, scope).incarnation)
    end

    test "does not change while the tracker runs", %{scope: scope, rollcall: rollcall} do
      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_1", %{})
      incarnation = Tracker.get_state(rollcall, scope).incarnation

      {:ok, _ref} = Rollcall.track(rollcall, self(), scope, "partition", "key_2", %{})

      assert Tracker.get_state(rollcall, scope).incarnation == incarnation
    end
  end

  defp local_entries(rollcall, scope, partition) do
    rollcall
    |> Tracker.get_state(scope)
    |> Map.fetch!(:local)
    |> Local.entries(partition)
  end
end
