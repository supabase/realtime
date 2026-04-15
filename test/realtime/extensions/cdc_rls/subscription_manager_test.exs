defmodule Realtime.Extensions.CdcRls.SubscriptionManagerTest do
  # async: false due to global Mimic stubs
  use Realtime.DataCase, async: false
  use Mimic

  alias Extensions.PostgresCdcRls
  alias Extensions.PostgresCdcRls.SubscriptionManager
  alias Extensions.PostgresCdcRls.Subscriptions
  alias Realtime.Database
  alias Realtime.Tenants.Rebalancer

  import ExUnit.CaptureLog

  setup do
    tenant = Containers.checkout_tenant(run_migrations: true)
    {:ok, db_conn} = Realtime.Database.connect(tenant, "realtime_test", :stop)
    Integrations.setup_postgres_changes(db_conn)
    GenServer.stop(db_conn)
    Realtime.Tenants.Cache.update_cache(tenant)

    subscribers_pids_table = :ets.new(__MODULE__, [:public, :bag])
    subscribers_nodes_table = :ets.new(__MODULE__, [:public, :set])

    args = %{
      "id" => tenant.external_id,
      "subscribers_nodes_table" => subscribers_nodes_table,
      "subscribers_pids_table" => subscribers_pids_table
    }

    publication = "supabase_realtime_test"

    # register this process with syn as if this was the WorkersSupervisor

    scope = Realtime.Syn.PostgresCdc.scope(tenant.external_id)
    :syn.register(scope, tenant.external_id, self(), %{region: "us-east-1", manager: nil, subs_pool: nil})

    {:ok, pid} = SubscriptionManager.start_link(args)
    # This serves so that we know that handle_continue has finished
    :sys.get_state(pid)
    %{args: args, pid: pid, publication: publication}
  end

  describe "subscription" do
    test "subscription", %{pid: pid, args: args, publication: publication} do
      {:ok, ^pid, conn} = PostgresCdcRls.get_manager_conn(args["id"])
      {uuid, bin_uuid, pg_change_params} = pg_change_params()

      subscriber = self()

      assert {:ok, [%Postgrex.Result{command: :insert}]} =
               Subscriptions.create(conn, publication, [pg_change_params], pid, subscriber)

      # Wait for subscription manager to process the :subscribed message
      :sys.get_state(pid)

      node = node()

      assert [{^subscriber, ^uuid, _ref, ^node}] = :ets.tab2list(args["subscribers_pids_table"])

      assert :ets.tab2list(args["subscribers_nodes_table"]) == [{bin_uuid, node}]
    end

    test "subscriber died", %{pid: pid, args: args, publication: publication} do
      {:ok, ^pid, conn} = PostgresCdcRls.get_manager_conn(args["id"])
      self = self()

      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      {uuid1, bin_uuid1, pg_change_params1} = pg_change_params()
      {uuid2, bin_uuid2, pg_change_params2} = pg_change_params()
      {uuid3, bin_uuid3, pg_change_params3} = pg_change_params()

      assert {:ok, _} =
               Subscriptions.create(conn, publication, [pg_change_params1, pg_change_params2], pid, subscriber)

      assert {:ok, _} = Subscriptions.create(conn, publication, [pg_change_params3], pid, self())

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
    test "subscription is deleted when process goes away", %{pid: pid, args: args, publication: publication} do
      {:ok, ^pid, conn} = PostgresCdcRls.get_manager_conn(args["id"])
      {_uuid, _bin_uuid, pg_change_params} = pg_change_params()

      subscriber =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      %Postgrex.Result{rows: [[baseline]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])

      assert {:ok, [%Postgrex.Result{command: :insert}]} =
               Subscriptions.create(conn, publication, [pg_change_params], pid, subscriber)

      # Wait for subscription manager to process the :subscribed message
      :sys.get_state(pid)

      assert :ets.info(args["subscribers_pids_table"], :size) == 1
      assert :ets.info(args["subscribers_nodes_table"], :size) == 1

      %Postgrex.Result{rows: [[after_create]]} = Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
      assert after_create > baseline

      send(subscriber, :stop)
      # Wait for subscription manager to receive the :DOWN message
      Process.sleep(200)

      assert :ets.info(args["subscribers_pids_table"], :size) == 0
      assert :ets.info(args["subscribers_nodes_table"], :size) == 0

      # Force check delete queue on manager
      send(pid, :check_delete_queue)
      :sys.get_state(pid)

      assert %Postgrex.Result{rows: [[^baseline]]} =
               Postgrex.query!(conn, "select count(*) from realtime.subscription", [])
    end
  end

  describe "check no users" do
    test "exit is sent to manager", %{pid: pid} do
      :sys.replace_state(pid, fn state -> %{state | no_users_ts: 0} end)

      send(pid, :check_no_users)

      assert_receive {:system, {^pid, _}, {:terminate, :shutdown}}
    end
  end

  describe "message handling" do
    setup :set_mimic_global

    test "re-subscribes all subscribers when publication oids change", %{pid: pid, args: args} do
      # Force state to have different oids so the new_oids branch is triggered when
      # fetch_publication_tables returns the real oids from the database
      :sys.replace_state(pid, fn state -> %{state | oids: %{fake: :oids_that_dont_match}} end)
      :ets.insert(args["subscribers_pids_table"], {self(), UUID.uuid1(), make_ref(), node()})

      send(pid, :check_oids)

      assert_receive :postgres_subscribe, 1000
      assert :ets.tab2list(args["subscribers_pids_table"]) == []
      assert :ets.tab2list(args["subscribers_nodes_table"]) == []
    end

    test "logs error when subscription deletion fails during check_delete_queue", %{
      pid: pid,
      args: args,
      publication: publication
    } do
      {:ok, ^pid, conn} = PostgresCdcRls.get_manager_conn(args["id"])
      {_uuid, _bin_uuid, pg_change_params} = pg_change_params()

      subscriber = spawn(fn -> receive do: (:stop -> :ok) end)
      Subscriptions.create(conn, publication, [pg_change_params], pid, subscriber)
      :sys.get_state(pid)

      stub(Subscriptions, :delete_multi, fn _conn, _ids -> {:error, :delete_failed} end)

      send(subscriber, :stop)
      Process.sleep(100)

      log =
        capture_log(fn ->
          send(pid, :check_delete_queue)
          :sys.get_state(pid)
        end)

      assert log =~ "SubscriptionDeletionFailed"
    end

    test "schedules next region check when rebalancer returns ok", %{pid: pid} do
      # In a single-node test environment, nodes are equal → Rebalancer returns :ok
      current_nodes = MapSet.new(Node.list())
      send(pid, {:check_region, current_nodes})
      :sys.get_state(pid)

      assert Process.alive?(pid)
    end

    test "calls handle_stop when wrong region detected", %{pid: pid} do
      stub(Rebalancer, :check, fn _prev, _curr, _id -> {:error, :wrong_region} end)
      stub(PostgresCdcRls, :handle_stop, fn _id, _timeout -> :ok end)

      send(pid, {:check_region, MapSet.new()})
      :sys.get_state(pid)

      assert Process.alive?(pid)
    end
  end

  test "handles empty delete queue without crashing", %{pid: pid} do
    send(pid, :check_delete_queue)
    state = :sys.get_state(pid)
    assert :queue.is_empty(state.delete_queue.queue)
  end

  test "handles unhandled messages without crashing", %{pid: pid} do
    state_before = :sys.get_state(pid)
    send(pid, :totally_unexpected_message)
    state_after = :sys.get_state(pid)
    assert state_before.id == state_after.id
  end

  describe "error handling" do
    setup :set_mimic_global

    test "stops cleanly when database connection fails", %{args: args} do
      stub(Database, :connect_db, fn _settings -> {:error, :econnrefused} end)

      pid = start_supervised!({SubscriptionManager, args}, restart: :temporary)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :econnrefused}, 1000
    end
  end

  defp pg_change_params do
    uuid = UUID.uuid1()

    pg_change_params = %{
      id: uuid,
      subscription_params: {"*", "public", "*", []},
      claims: %{
        "exp" => System.system_time(:second) + 100_000,
        "iat" => 0,
        "role" => "anon"
      }
    }

    {uuid, UUID.string_to_binary!(uuid), pg_change_params}
  end
end
