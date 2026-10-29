defmodule Rollcall.TrackerStateTest do
  use Rollcall.Case, async: true

  alias Rollcall.Tracker
  alias Rollcall.Tracker.Local

  describe "get_state/1" do
    test "returns nil when no tracker runs", %{scope: scope} do
      assert Tracker.get_state(scope) == nil
    end

    test "does not start a tracker", %{scope: scope} do
      Tracker.get_state(scope)

      refute scope in Rollcall.scopes()
    end

    test "returns the scope of the tracker", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})

      assert %{scope: ^scope} = Tracker.get_state(scope)
    end
  end

  describe "track/5 refs" do
    test "returns different refs for different keys", %{scope: scope} do
      {:ok, ref_1} = Rollcall.track(self(), scope, "partition", "key_1", %{})
      {:ok, ref_2} = Rollcall.track(self(), scope, "partition", "key_2", %{})

      refute ref_1 == ref_2
    end

    test "returns different refs when the same key is tracked again", %{scope: scope} do
      {:ok, ref_1} = Rollcall.track(self(), scope, "partition", "key", %{a: 1})
      {:ok, ref_2} = Rollcall.track(self(), scope, "partition", "key", %{a: 1})

      refute ref_1 == ref_2
    end

    test "returns different refs for different pids", %{scope: scope} do
      other = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, ref_1} = Rollcall.track(self(), scope, "partition", "key", %{})
      {:ok, ref_2} = Rollcall.track(other, scope, "partition", "key", %{})

      Process.exit(other, :kill)
      refute ref_1 == ref_2
    end

    test "returns different refs in different scopes", %{scope: scope} do
      {:ok, ref_1} = Rollcall.track(self(), scope, "partition", "key", %{})
      {:ok, ref_2} = Rollcall.track(self(), unique_scope(), "partition", "key", %{})

      refute ref_1 == ref_2
    end
  end

  describe "track/5 local entries" do
    test "stores the entry with the returned ref", %{scope: scope} do
      pid = self()
      {:ok, ref} = Rollcall.track(pid, scope, "partition", "key", %{a: 1})

      assert [%{ref: ^ref, pid: ^pid, partition: "partition", key: "key", meta: %{a: 1}}] =
               local_entries(scope, "partition")
    end

    test "replaces the entry when the same key is tracked again", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{a: 1})
      {:ok, ref} = Rollcall.track(self(), scope, "partition", "key", %{a: 2})

      assert [%{ref: ^ref, meta: %{a: 2}}] = local_entries(scope, "partition")
    end

    test "keeps the entries of different partitions apart", %{scope: scope} do
      {:ok, ref_1} = Rollcall.track(self(), scope, "partition_1", "key", %{})
      {:ok, ref_2} = Rollcall.track(self(), scope, "partition_2", "key", %{})

      assert [%{ref: ^ref_1}] = local_entries(scope, "partition_1")
      assert [%{ref: ^ref_2}] = local_entries(scope, "partition_2")
    end
  end

  describe "untrack/4 local entries" do
    test "removes the entry", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
      {:ok, ref_2} = Rollcall.track(self(), scope, "partition", "key_2", %{})

      :ok = Rollcall.untrack(self(), scope, "partition", "key_1")

      assert [%{ref: ^ref_2}] = local_entries(scope, "partition")
    end
  end

  describe "version" do
    test "is 1 after the first track", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})

      assert Tracker.get_state(scope).version == 1
    end

    test "increments for a track of another key", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})

      assert Tracker.get_state(scope).version == 2
    end

    test "increments once when the same key is tracked again", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{a: 1})
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{a: 2})

      assert Tracker.get_state(scope).version == 2
    end

    test "increments when the same key is tracked again with the same meta", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{a: 1})
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{a: 1})

      assert Tracker.get_state(scope).version == 2
    end

    test "increments for an untrack that removes an entry", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})

      :ok = Rollcall.untrack(self(), scope, "partition", "key_1")

      assert Tracker.get_state(scope).version == 3
    end

    test "does not change for an untrack that removes nothing", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})

      :ok = Rollcall.untrack(self(), scope, "partition", "other_key")

      assert Tracker.get_state(scope).version == 1
    end
  end

  describe "incarnation" do
    test "is an integer", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key", %{})

      assert is_integer(Tracker.get_state(scope).incarnation)
    end

    test "does not change while the tracker runs", %{scope: scope} do
      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_1", %{})
      incarnation = Tracker.get_state(scope).incarnation

      {:ok, _ref} = Rollcall.track(self(), scope, "partition", "key_2", %{})

      assert Tracker.get_state(scope).incarnation == incarnation
    end
  end

  defp local_entries(scope, partition) do
    scope
    |> Tracker.get_state()
    |> Map.fetch!(:local)
    |> Local.entries(partition)
  end
end
