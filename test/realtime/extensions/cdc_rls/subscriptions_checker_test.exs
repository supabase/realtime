defmodule Realtime.Extensions.PostgresCdcRl.SubscriptionsCheckerTest do
  use ExUnit.Case, async: true
  alias Extensions.PostgresCdcRls.SubscriptionsChecker, as: Checker
  import UUID, only: [uuid1: 0, string_to_binary!: 1]

  test "subscribers_by_node/1" do
    subscribers_pids_table = :ets.new(:table, [:public, :bag])

    test_data = [
      {:pid1, "id1", :ref, :node1},
      {:pid1, "id1.2", :ref, :node1},
      {:pid2, "id2", :ref, :node2}
    ]

    :ets.insert(subscribers_pids_table, test_data)

    assert Checker.subscribers_by_node(subscribers_pids_table) == %{
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

  describe "pop_not_alive_pids/4" do
    test "one subscription per channel" do
      subscribers_pids_table = :ets.new(:table, [:public, :bag])
      subscribers_nodes_table = :ets.new(:table, [:public, :set])

      uuid1 = uuid1()
      uuid2 = uuid1()
      uuid3 = uuid1()

      pids_test_data = [
        {:pid1, uuid1, :ref, :node1},
        {:pid1, uuid2, :ref, :node1},
        {:pid2, uuid3, :ref, :node2}
      ]

      :ets.insert(subscribers_pids_table, pids_test_data)

      nodes_test_data = [
        {string_to_binary!(uuid1), :node1},
        {string_to_binary!(uuid2), :node1},
        {string_to_binary!(uuid3), :node2}
      ]

      :ets.insert(subscribers_nodes_table, nodes_test_data)

      not_alive = Enum.sort(Checker.pop_not_alive_pids([:pid1], subscribers_pids_table, subscribers_nodes_table, "id"))
      expected = Enum.sort([string_to_binary!(uuid1), string_to_binary!(uuid2)])
      assert not_alive == expected

      assert :ets.tab2list(subscribers_pids_table) == [{:pid2, uuid3, :ref, :node2}]
      assert :ets.tab2list(subscribers_nodes_table) == [{string_to_binary!(uuid3), :node2}]
    end

    test "two subscriptions per channel" do
      subscribers_pids_table = :ets.new(:table, [:public, :bag])
      subscribers_nodes_table = :ets.new(:table, [:public, :set])

      uuid1 = uuid1()
      uuid2 = uuid1()

      test_data = [
        {:pid1, uuid1, :ref, :node1},
        {:pid2, uuid2, :ref, :node2}
      ]

      :ets.insert(subscribers_pids_table, test_data)

      nodes_test_data = [
        {string_to_binary!(uuid1), :node1},
        {string_to_binary!(uuid2), :node2}
      ]

      :ets.insert(subscribers_nodes_table, nodes_test_data)

      assert Checker.pop_not_alive_pids([:pid1], subscribers_pids_table, subscribers_nodes_table, "id") == [
               string_to_binary!(uuid1)
             ]

      assert :ets.tab2list(subscribers_pids_table) == [{:pid2, uuid2, :ref, :node2}]
      assert :ets.tab2list(subscribers_nodes_table) == [{string_to_binary!(uuid2), :node2}]
    end
  end
end
