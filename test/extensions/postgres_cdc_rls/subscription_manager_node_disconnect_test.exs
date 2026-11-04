defmodule Extensions.PostgresCdcRls.SubscriptionManagerNodeDisconnectTest do
  # async: false due to Clustered
  use Realtime.DataCase, async: false

  import ExUnit.CaptureLog

  alias Extensions.PostgresCdcRls
  alias Extensions.PostgresCdcRls.SubscriptionManager
  alias Extensions.PostgresCdcRls.Subscriptions

  @publication "supabase_realtime_test"

  # The SubscriptionManager runs on this node and the subscriber runs on a peer, so the manager
  # monitors a remote pid. Cutting the distribution link delivers a real
  # {:DOWN, ref, :process, pid, :noconnection} to the manager while the subscriber stays alive.
  setup do
    tenant = TestTenantDb.checkout_tenant_unboxed(run_migrations: true)
    {:ok, db_conn} = Realtime.Database.connect(tenant, "realtime_test", :stop)
    Integrations.setup_postgres_changes(db_conn)
    GenServer.stop(db_conn)
    Realtime.Tenants.Cache.update_cache(tenant)

    pids_table = :ets.new(__MODULE__, [:public, :bag])
    nodes_table = :ets.new(__MODULE__, [:public, :set])

    args = %{
      "id" => tenant.external_id,
      "subscribers_nodes_table" => nodes_table,
      "subscribers_pids_table" => pids_table
    }

    # Stand in for the WorkerSupervisor, so that update_meta/3 finds a registration
    scope = Realtime.Syn.PostgresCdc.scope(tenant.external_id)
    :syn.register(scope, tenant.external_id, self(), %{region: "us-east-1", manager: nil, subs_pool: nil})

    {:ok, manager} = SubscriptionManager.start_link(args)
    :sys.get_state(manager)
    {:ok, ^manager, conn} = PostgresCdcRls.get_manager_conn(tenant.external_id)

    {:ok, peer, remote_node} = Clustered.start_disconnected()
    true = Node.connect(remote_node)

    %{
      manager: manager,
      conn: conn,
      pids_table: pids_table,
      nodes_table: nodes_table,
      peer: peer,
      remote_node: remote_node
    }
  end

  test "a subscriber node that disconnects and reconnects keeps its subscription", ctx do
    %{manager: manager, conn: conn, nodes_table: nodes_table, remote_node: remote_node} = ctx
    subscriber = Node.spawn(remote_node, Process, :sleep, [:infinity])
    {uuid, bin_uuid, params} = pg_change_params()

    subscribe(conn, manager, params, subscriber)
    assert monitoring?(manager, subscriber)

    reconnect(manager, subscriber, remote_node)

    assert :erpc.call(remote_node, Process, :alive?, [subscriber])

    # On the disconnect, :syn on the subscriber node drops the CDC tree registration, so the
    # channel gets postgres_cdc_down and subscribes again with the same subscription id.
    subscribe(conn, manager, params, subscriber)

    send(manager, :check_delete_queue)
    :sys.get_state(manager)

    assert subscription_rows(conn, uuid) > 0, "the live subscriber lost its realtime.subscription rows"
    assert [{^bin_uuid, ^remote_node}] = :ets.lookup(nodes_table, bin_uuid)
  end

  test "a subscriber node that reconnects after the delete runs gets its subscription back", ctx do
    %{manager: manager, conn: conn, nodes_table: nodes_table, remote_node: remote_node} = ctx
    subscriber = Node.spawn(remote_node, Process, :sleep, [:infinity])
    {uuid, bin_uuid, params} = pg_change_params()

    subscribe(conn, manager, params, subscriber)
    reconnect(manager, subscriber, remote_node)

    # The delete timer fires before the channel's resubscribe backoff ends.
    send(manager, :check_delete_queue)
    :sys.get_state(manager)
    assert subscription_rows(conn, uuid) == 0

    subscribe(conn, manager, params, subscriber)
    assert monitoring?(manager, subscriber)

    send(manager, :check_delete_queue)
    :sys.get_state(manager)

    assert subscription_rows(conn, uuid) > 0, "the resubscribe did not restore the realtime.subscription rows"
    assert [{^bin_uuid, ^remote_node}] = :ets.lookup(nodes_table, bin_uuid)
  end

  test "a subscriber that leaves after its node reconnects is cleaned up", ctx do
    %{manager: manager, conn: conn, pids_table: pids_table, remote_node: remote_node} = ctx
    subscriber = Node.spawn(remote_node, Process, :sleep, [:infinity])
    {uuid, _bin_uuid, params} = pg_change_params()

    subscribe(conn, manager, params, subscriber)
    reconnect(manager, subscriber, remote_node)
    subscribe(conn, manager, params, subscriber)
    send(manager, :check_delete_queue)
    :sys.get_state(manager)

    # The channel leaves. Its :DOWN is the only prompt cleanup path: check_active_pids runs
    # every 2 minutes.
    Process.exit(subscriber, :kill)
    await_down(manager, subscriber)

    send(manager, :check_delete_queue)
    :sys.get_state(manager)

    assert :ets.lookup(pids_table, subscriber) == [], "the manager did not notice the subscriber exit"
    assert subscription_rows(conn, uuid) == 0
  end

  test "a subscriber node that leaves for good does not leave its subscription behind", ctx do
    %{manager: manager, conn: conn, pids_table: pids_table, peer: peer, remote_node: remote_node} = ctx
    subscriber = Node.spawn(remote_node, Process, :sleep, [:infinity])
    {uuid, _bin_uuid, params} = pg_change_params()

    subscribe(conn, manager, params, subscriber)

    # Nodes are replaced under new names, so this node name never comes back.
    :peer.stop(peer)
    await_down(manager, subscriber)

    capture_log(fn ->
      send(manager, :check_active_pids)
      send(manager, :check_delete_queue)
      :sys.get_state(manager)
    end)

    assert :ets.lookup(pids_table, subscriber) == [], "the dead node's subscriber stays in ETS"
    assert subscription_rows(conn, uuid) == 0, "the dead node's realtime.subscription rows stay"
  end

  defp subscribe(conn, manager, params, subscriber) do
    assert {:ok, [%Postgrex.Result{command: :insert}]} =
             Subscriptions.create(conn, @publication, [params], manager, subscriber)

    :sys.get_state(manager)
  end

  # Dropping the link fires every monitor across it with :noconnection, even when the nodes
  # reconnect right away. Nothing here needs the split to last, so a plain reconnect is enough.
  defp reconnect(manager, subscriber, remote_node) do
    true = Node.disconnect(remote_node)
    await_down(manager, subscriber)
    true = Node.connect(remote_node)
  end

  # The monitor leaves Process.info/2 once the :DOWN signal turns into a message. A
  # :sys.get_state/1 sent after that point runs after the :DOWN handler.
  defp await_down(manager, subscriber) do
    assert_eventually not monitoring?(manager, subscriber)
    :sys.get_state(manager)
  end

  defp monitoring?(manager, pid) do
    {:monitors, monitors} = Process.info(manager, :monitors)
    {:process, pid} in monitors
  end

  defp subscription_rows(conn, uuid) do
    %Postgrex.Result{rows: [[count]]} =
      Postgrex.query!(conn, "select count(*) from realtime.subscription where subscription_id = $1::uuid", [
        UUID.string_to_binary!(uuid)
      ])

    count
  end

  defp pg_change_params do
    uuid = UUID.uuid1()

    params = %{
      id: uuid,
      subscription_params: {"*", "public", "*", [], nil},
      claims: %{"exp" => System.system_time(:second) + 100_000, "iat" => 0, "role" => "anon"}
    }

    {uuid, UUID.string_to_binary!(uuid), params}
  end
end
