defmodule SubscriptionsCheckerTest do
  use ExUnit.Case
  alias Extensions.PostgresCdcRls.SubscriptionsChecker, as: Checker

  test "subscribers_by_node/1" do
    tid = :ets.new(:table, [:public, :bag])

    test_data = [
      {:pid1, "id1", :ref, :node1},
      {:pid1, "id1.2", :ref, :node1},
      {:pid2, "id2", :ref, :node2}
    ]

    :ets.insert(tid, test_data)

    result = Checker.subscribers_by_node(tid)

    assert Checker.subscribers_by_node(tid) == %{
             node1: MapSet.new([:pid1]),
             node2: MapSet.new([:pid2])
           }
  end

  describe "not_alive_pids/1" do
    test "returns empty list for empty input" do
      assert Checker.not_alive_pids(MapSet.new()) == []
    end

    test "returns empty list for all alive PIDs" do
      pid1 = spawn(fn -> Process.sleep(5000) end)
      pid2 = spawn(fn -> Process.sleep(5000) end)
      pid3 = spawn(fn -> Process.sleep(5000) end)
      assert Checker.not_alive_pids(MapSet.new([pid1, pid2, pid3])) == []
    end

    test "returns list of dead PIDs" do
      pid1 = spawn(fn -> Process.sleep(5000) end)
      pid2 = spawn(fn -> Process.sleep(5000) end)
      pid3 = spawn(fn -> Process.sleep(5000) end)
      Process.exit(pid2, :kill)
      assert Checker.not_alive_pids(MapSet.new([pid1, pid2, pid3])) == [pid2]
    end
  end

  describe "pop_not_alive_pids/2" do
    test "one subscription per channel" do
      tid = :ets.new(:table, [:public, :bag])

      uuid1 = UUID.uuid1()
      uuid2 = UUID.uuid1()

      test_data = [
        {:pid1, uuid1, :ref, :node1},
        {:pid1, uuid2, :ref, :node1},
        {:pid2, "uuid", :ref, :node2}
      ]

      :ets.insert(tid, test_data)

      assert Checker.pop_not_alive_pids([:pid1], tid) == [
               UUID.string_to_binary!(uuid1),
               UUID.string_to_binary!(uuid2)
             ]

      assert :ets.tab2list(tid) == [{:pid2, "uuid", :ref, :node2}]
    end

    test "two subscriptions per channel" do
      tid = :ets.new(:table, [:public, :bag])

      uuid1 = UUID.uuid1()

      test_data = [
        {:pid1, uuid1, :ref, :node1},
        {:pid2, "uuid", :ref, :node2}
      ]

      :ets.insert(tid, test_data)
      assert Checker.pop_not_alive_pids([:pid1], tid) == [UUID.string_to_binary!(uuid1)]
      assert :ets.tab2list(tid) == [{:pid2, "uuid", :ref, :node2}]
    end
  end
end
