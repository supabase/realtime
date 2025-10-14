defmodule Realtime.Extensions.CdcRls.SubscritionManagerTest do
  use Realtime.DataCase, async: true

  alias Extensions.PostgresCdcRls
  alias Extensions.PostgresCdcRls.SubscriptionManager

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)

    subscribers_pids_table = :ets.new(__MODULE__, [:public, :bag])
    subscribers_nodes_table = :ets.new(__MODULE__, [:public, :set])

    args =
      hd(tenant.extensions).settings
      |> Map.put("id", tenant.external_id)
      |> Map.put("subscribers_pids_table", subscribers_pids_table)
      |> Map.put("subscribers_nodes_table", subscribers_nodes_table)

    # register this process with syn as if this was the WorkersSupervisor
    :syn.register(PostgresCdcRls, tenant.external_id, self(), %{region: "us-east-1", manager: nil, subs_pool: nil})

    {:ok, pid} = SubscriptionManager.start_link(Map.put(args, "id", tenant.external_id))
    # This serves so that we know that handle_continue has finished
    :sys.get_state(pid)
    %{args: args, pid: pid}
  end

  describe "subscription" do
    test "subscription", %{pid: pid, args: args} do
      {uuid, bin_uuid} = uuid()

      subscriber = self()

      send(pid, {:subscribed, {subscriber, uuid}})
      # Wait for subscription manager to process the :subscribed message
      :sys.get_state(pid)

      node = node()

      assert [{^subscriber, ^uuid, _ref, ^node}] = :ets.tab2list(args["subscribers_pids_table"])

      assert :ets.tab2list(args["subscribers_nodes_table"]) == [{bin_uuid, node}]
    end

    test "subscriber died", %{pid: pid, args: args} do
      self = self()

      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {uuid1, bin_uuid1} = uuid()
      {uuid2, bin_uuid2} = uuid()
      {uuid3, bin_uuid3} = uuid()

      send(pid, {:subscribed, {subscriber, uuid1}})
      send(pid, {:subscribed, {subscriber, uuid2}})
      send(pid, {:subscribed, {self(), uuid3}})
      # Wait for subscription manager to process the :subscribed message
      :sys.get_state(pid)

      node = node()

      assert :ets.info(args["subscribers_pids_table"], :size) == 3

      assert [{^subscriber, ^uuid1, _, ^node}, {^subscriber, ^uuid2, _, ^node}] =
               :ets.lookup(args["subscribers_pids_table"], subscriber)

      assert [{^self, ^uuid3, _ref, ^node}] = :ets.lookup(args["subscribers_pids_table"], self)

      assert :ets.info(args["subscribers_nodes_table"], :size) == 3
      assert [{^bin_uuid1, ^node}] = :ets.lookup(args["subscribers_nodes_table"], bin_uuid1)
      assert [{^bin_uuid2, ^node}] = :ets.lookup(args["subscribers_nodes_table"], bin_uuid2)
      assert [{^bin_uuid3, ^node}] = :ets.lookup(args["subscribers_nodes_table"], bin_uuid3)

      send(subscriber, :stop)
      # Wait for subscription manager to receive the :DOWN message
      Process.sleep(200)

      # Only the subscription we have not stopped should remain

      assert [{^self, ^uuid3, _ref, ^node}] = :ets.tab2list(args["subscribers_pids_table"])
      assert [{^bin_uuid3, ^node}] = :ets.tab2list(args["subscribers_nodes_table"])
    end
  end

  describe "subscription deletion" do
    test "subscription is deleted when process goes away", %{pid: pid, args: args} do
      {uuid, _bin_uuid} = uuid()

      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      send(pid, {:subscribed, {subscriber, uuid}})
      # Wait for subscription manager to process the :subscribed message
      :sys.get_state(pid)

      assert :ets.info(args["subscribers_pids_table"], :size) == 1
      assert :ets.info(args["subscribers_nodes_table"], :size) == 1

      send(subscriber, :stop)
      # Wait for subscription manager to receive the :DOWN message
      Process.sleep(200)

      assert :ets.info(args["subscribers_pids_table"], :size) == 0
      assert :ets.info(args["subscribers_nodes_table"], :size) == 0

      # Force check delete queue on manager
      send(pid, :check_delete_queue)
      Process.sleep(200)
    end
  end

  describe "check no users" do
    test "exit is sent to manager", %{pid: pid} do
      :sys.replace_state(pid, fn state -> %{state | no_users_ts: 0} end)

      send(pid, :check_no_users)

      assert_receive {:system, {^pid, _}, {:terminate, :shutdown}}
    end
  end

  defp uuid do
    uuid = UUID.uuid1()

    {uuid, UUID.string_to_binary!(uuid)}
  end
end
