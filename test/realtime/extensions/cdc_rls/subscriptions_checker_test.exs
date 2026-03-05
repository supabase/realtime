defmodule Realtime.Extensions.PostgresCdcRl.SubscriptionsCheckerTest do
  use Realtime.DataCase, async: false
  use Mimic

  setup :set_mimic_global

  alias Extensions.PostgresCdcRls.SubscriptionsChecker, as: Checker
  alias Realtime.Database
  alias Realtime.GenRpc
  import ExUnit.CaptureLog
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

  describe "handle_continue connection failure" do
    test "stops GenServer when database connection fails" do
      tenant = Containers.checkout_tenant(run_migrations: true)

      stub(Database, :connect_db, fn _settings -> {:error, :econnrefused} end)

      args =
        hd(tenant.extensions).settings
        |> Map.put("id", tenant.external_id)
        |> Map.put("subscribers_pids_table", :ets.new(:table, [:public, :bag]))
        |> Map.put("subscribers_nodes_table", :ets.new(:table, [:public, :set]))

      pid = start_supervised!({Checker, args}, restart: :temporary)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :econnrefused}, 2000
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

    test "returns empty list when pid not found in table" do
      subscribers_pids_table = :ets.new(:table, [:public, :bag])
      subscribers_nodes_table = :ets.new(:table, [:public, :set])

      assert Checker.pop_not_alive_pids(
               [:nonexistent_pid],
               subscribers_pids_table,
               subscribers_nodes_table,
               "tenant_id"
             ) == []
    end
  end

  describe "not_alive_pids_dist/1" do
    test "handles remote node RPC error gracefully" do
      remote_node = :some_remote@node

      stub(GenRpc, :call, fn ^remote_node, Checker, :not_alive_pids, _pids, _opts ->
        {:error, :rpc_error, :timeout}
      end)

      log =
        capture_log(fn ->
          result = Checker.not_alive_pids_dist(%{remote_node => MapSet.new([self()])})
          assert result == []
        end)

      assert log =~ "UnableToCheckProcessesOnRemoteNode"
    end

    test "returns pids from remote node when RPC succeeds" do
      remote_node = :some_remote@node
      dead_pid = self()

      stub(GenRpc, :call, fn ^remote_node, Checker, :not_alive_pids, [pids_set], _opts ->
        MapSet.to_list(pids_set)
      end)

      result = Checker.not_alive_pids_dist(%{remote_node => MapSet.new([dead_pid])})
      assert dead_pid in result
    end

    test "checks local pids directly without RPC" do
      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      receive do: ({:DOWN, ^ref, :process, ^dead_pid, _} -> :ok)

      result = Checker.not_alive_pids_dist(%{node() => MapSet.new([dead_pid])})
      assert dead_pid in result
    end
  end

  describe "GenServer handle_info integration" do
    setup do
      tenant = Containers.checkout_tenant(run_migrations: true)
      Realtime.Tenants.Cache.update_cache(tenant)

      subscribers_pids_table = :ets.new(:sub_pids, [:public, :bag])
      subscribers_nodes_table = :ets.new(:sub_nodes, [:public, :set])

      args = %{
        "id" => tenant.external_id,
        "subscribers_pids_table" => subscribers_pids_table,
        "subscribers_nodes_table" => subscribers_nodes_table
      }

      pid = start_link_supervised!({Checker, args})
      :sys.get_state(pid)

      %{pid: pid, subscribers_pids_table: subscribers_pids_table, subscribers_nodes_table: subscribers_nodes_table}
    end

    test "check_active_pids adds dead pids to delete queue", %{
      pid: pid,
      subscribers_pids_table: subscribers_pids_table,
      subscribers_nodes_table: subscribers_nodes_table
    } do
      dead_pid = spawn(fn -> :ok end)
      ref = Process.monitor(dead_pid)
      receive do: ({:DOWN, ^ref, :process, ^dead_pid, _} -> :ok)
      u = uuid1()
      bin_u = string_to_binary!(u)

      :ets.insert(subscribers_pids_table, {dead_pid, u, make_ref(), node()})
      :ets.insert(subscribers_nodes_table, {bin_u, node()})

      send(pid, :check_active_pids)
      :sys.get_state(pid)

      state = :sys.get_state(pid)
      assert not :queue.is_empty(state.delete_queue.queue)
    end

    test "check_delete_queue processes items in queue", %{pid: pid} do
      bin_id = string_to_binary!(uuid1())

      :sys.replace_state(pid, fn state ->
        %{state | delete_queue: %{ref: nil, queue: :queue.in(bin_id, :queue.new())}}
      end)

      send(pid, :check_delete_queue)
      state = :sys.get_state(pid)

      assert :queue.is_empty(state.delete_queue.queue)
    end

    test "check_delete_queue logs error when deletion fails", %{pid: pid} do
      stub(Extensions.PostgresCdcRls.Subscriptions, :delete_multi, fn _conn, _ids ->
        {:error, :deletion_failed}
      end)

      bin_id = string_to_binary!(uuid1())

      :sys.replace_state(pid, fn state ->
        %{state | delete_queue: %{ref: nil, queue: :queue.in(bin_id, :queue.new())}}
      end)

      log =
        capture_log(fn ->
          send(pid, :check_delete_queue)
          :sys.get_state(pid)
        end)

      assert log =~ "UnableToDeletePhantomSubscriptions"
    end
  end
end
