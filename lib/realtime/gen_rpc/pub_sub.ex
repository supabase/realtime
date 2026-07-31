defmodule Realtime.GenRpcPubSub do
  @moduledoc """
  gen_rpc Phoenix.PubSub adapter
  """

  @behaviour Phoenix.PubSub.Adapter
  alias Forum.Muster
  alias Realtime.FeatureFlags
  alias Realtime.GenRpc
  alias Realtime.GenRpcPubSub.Worker
  alias Realtime.Nodes
  use Supervisor

  @impl true
  def node_name(_), do: node()

  # Supervisor callbacks

  def start_link(opts) do
    adapter_name = Keyword.fetch!(opts, :adapter_name)
    name = Keyword.fetch!(opts, :name)
    pool_size = Keyword.get(opts, :pool_size, 1)
    broadcast_pool_size = Keyword.get(opts, :broadcast_pool_size, pool_size)

    Supervisor.start_link(__MODULE__, {adapter_name, name, broadcast_pool_size},
      name: :"#{name}#{adapter_name}_supervisor"
    )
  end

  @impl true
  def init({adapter_name, pubsub, pool_size}) do
    workers = for number <- 1..pool_size, do: :"#{pubsub}#{adapter_name}_#{number}"

    :persistent_term.put(adapter_name, List.to_tuple(workers))

    children =
      for worker <- workers do
        Supervisor.child_spec({Realtime.GenRpcPubSub.Worker, {pubsub, worker}}, id: worker)
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp worker_name(adapter_name, key) do
    workers = :persistent_term.get(adapter_name)
    elem(workers, :erlang.phash2(key, tuple_size(workers)))
  end

  @impl true
  def broadcast(adapter_name, topic, {:tb, tenant_id, _inner} = message, dispatcher) do
    if FeatureFlags.enabled?("use_muster_broadcast", tenant_id) do
      muster_broadcast(adapter_name, topic, tenant_id, message, dispatcher)
    else
      flood_all(adapter_name, topic, message, dispatcher)
    end
  end

  def broadcast(adapter_name, topic, message, dispatcher) do
    flood_all(adapter_name, topic, message, dispatcher)
  end

  # Original behavior: fan a broadcast out to every other node in the region (:ftl)
  # plus one representative per other region (:ftr, which re-floods its own region).
  defp flood_all(adapter_name, topic, message, dispatcher) do
    worker = worker_name(adapter_name, self())
    my_region = Application.get_env(:realtime, :region)

    intra_region_flood(worker, my_region, topic, message, dispatcher)

    # send a message to a node in each region to forward to the rest of the region
    other_region_nodes = nodes_from_other_regions(my_region, self())
    GenRpc.abcast(other_region_nodes, worker, Worker.forward_to_region(topic, message, dispatcher), key: self())

    :ok
  end

  # Feature-flagged (`use_muster_broadcast`): within the origin's own region, ask
  # Muster which nodes actually hold the tenant and deliver only to those, instead
  # of flooding the whole region. Cross-region delivery is unchanged (still flooded
  # via :ftr) because the origin does not participate in other regions' Muster rings
  # and therefore cannot know their router.
  #
  # NOTE: correctness relies on the tenant's connections being registered in Muster
  # (the separate `use_muster_channel_join` flag). Enable this flag only for tenants
  # that already have that one on, otherwise `Muster.targets/3` legitimately returns
  # an empty set and remote deliveries are dropped.
  defp muster_broadcast(adapter_name, topic, tenant_id, message, dispatcher) do
    worker = worker_name(adapter_name, self())
    my_region = Application.get_env(:realtime, :region)
    scope = Application.get_env(:realtime, :muster_scope)

    # Cross-region: unchanged flooding (v1 does not Muster-route across regions).
    other_region_nodes = nodes_from_other_regions(my_region, self())
    GenRpc.abcast(other_region_nodes, worker, Worker.forward_to_region(topic, message, dispatcher), key: self())

    # Intra-region: route to the node Muster says owns this tenant's occupancy.
    case Muster.router(scope, tenant_id) do
      {:ok, router_node} when router_node == node() ->
        # We are the router: resolve the targets right here and :ftl them, rather than
        # bouncing the work through our own worker's mailbox. The origin already
        # delivered to its local subscribers via Phoenix, so it is excluded.
        nodes = Worker.targets_or_flood(scope, tenant_id, my_region, Muster.view_hash(scope))
        abcast_local(worker, nodes, topic, message, dispatcher)

      {:ok, router_node} ->
        # Remote router: hand it the routing decision over the network. Fire-and-forget,
        # never a synchronous RPC on the broadcast hot path.
        route = Worker.route(scope, tenant_id, topic, message, dispatcher, node(), Muster.view_hash(scope))
        GenRpc.abcast([router_node], worker, route, key: self())

      {:rebalancing, _members} ->
        # Routing is unreliable while the ring is in flux: over-deliver to the
        # whole region (minus the origin, which already delivered locally).
        intra_region_flood(worker, my_region, topic, message, dispatcher)
    end

    :ok
  end

  # Origin-side :ftl to `nodes`, excluding this node: the origin already delivered to
  # its own subscribers via Phoenix.PubSub's local dispatch.
  defp abcast_local(worker, nodes, topic, message, dispatcher) do
    other_nodes = for n <- nodes, n != node(), do: n
    GenRpc.abcast(other_nodes, worker, Worker.forward_to_local(topic, message, dispatcher), key: self())
    :ok
  end

  defp intra_region_flood(worker, my_region, topic, message, dispatcher) do
    abcast_local(worker, Realtime.Nodes.region_nodes(my_region), topic, message, dispatcher)
  end

  defp nodes_from_other_regions(my_region, key) do
    Enum.flat_map(Nodes.all_node_regions(), fn
      ^my_region ->
        []

      region ->
        case Nodes.node_from_region(region, key) do
          {:ok, node} -> [node]
          _ -> []
        end
    end)
  end

  @impl true
  def direct_broadcast(adapter_name, node_name, topic, message, dispatcher) do
    worker = worker_name(adapter_name, self())
    GenRpc.abcast([node_name], worker, Worker.forward_to_local(topic, message, dispatcher), key: self())
  end
end

defmodule Realtime.GenRpcPubSub.Worker do
  @moduledoc false
  use GenServer
  require Logger

  def forward_to_local(topic, message, dispatcher), do: {:ftl, topic, message, dispatcher}
  def forward_to_region(topic, message, dispatcher), do: {:ftr, topic, message, dispatcher}

  def route(scope, tenant_id, topic, message, dispatcher, origin, view_hash),
    do: {:route, scope, tenant_id, topic, message, dispatcher, origin, view_hash}

  # Resolve the delivery set for a tenant broadcast when this node is the router
  def targets_or_flood(scope, tenant_id, my_region, view_hash) do
    case Forum.Muster.targets(scope, tenant_id, view_hash) do
      {:ok, nodes} -> nodes
      {:error, :flood} -> Realtime.Nodes.region_nodes(my_region)
    end
  end

  @doc false
  def start_link({pubsub, worker}), do: GenServer.start_link(__MODULE__, {pubsub, worker}, name: worker)

  @impl true
  def init({pubsub, worker}) do
    Process.flag(:message_queue_data, :off_heap)
    Process.flag(:fullsweep_after, 20)
    {:ok, {pubsub, worker}}
  end

  @impl true
  # Forward to local
  def handle_info({:ftl, topic, message, dispatcher}, {pubsub, worker}) do
    RealtimeWeb.TenantBroadcaster.measure_broadcast_fanout(message)
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)
    {:noreply, {pubsub, worker}}
  end

  # Forward to the rest of the region
  def handle_info({:ftr, topic, message, dispatcher}, {pubsub, worker}) do
    RealtimeWeb.TenantBroadcaster.measure_broadcast_fanout(message)

    # Forward to local first
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)

    # Then broadcast to the rest of my region, keeping the message intact so the
    # downstream :ftl handlers can attribute the fan-out too.
    my_region = Application.get_env(:realtime, :region)
    other_nodes = for node <- Realtime.Nodes.region_nodes(my_region), node != node(), do: node

    if other_nodes != [] do
      Realtime.GenRpc.abcast(other_nodes, worker, forward_to_local(topic, message, dispatcher), [])
    end

    {:noreply, {pubsub, worker}}
  end

  # Routed broadcast (feature flag `use_muster_broadcast`): the origin named us as the
  # router for `tenant_id`. Deliver only to the nodes Muster says hold the tenant.
  def handle_info(
        {:route, scope, tenant_id, topic, message, dispatcher, origin, view_hash},
        {pubsub, worker} = state
      ) do
    my_region = Application.get_env(:realtime, :region)

    # We are being extra catious here because Muster.targets/3 would already detect the different sender view hash
    # But this also covers if we have a bug and we just sent to the wrong node.
    nodes =
      case Forum.Muster.router(scope, tenant_id) do
        # Still the router: use the authoritative occupancy set, or over-deliver
        # to the whole region on a readiness/view-hash mismatch.
        {:ok, router_node} when router_node == node() ->
          targets_or_flood(scope, tenant_id, my_region, view_hash)

        # Router changed somehow, we have a bug or it's rebalancing at the moment
        _ ->
          Logger.warning("Muster router changed during broadcast for tenant #{tenant_id}, falling back to region flood")
          Realtime.Nodes.region_nodes(my_region)
      end

    dispatch_to_nodes(nodes, origin, pubsub, worker, topic, message, dispatcher)

    {:noreply, state}
  end

  @impl true
  def handle_info(_, pubsub), do: {:noreply, pubsub}

  # Deliver `message` to `nodes`, excluding `origin` (which already delivered to its
  # own subscribers via Phoenix.PubSub's local dispatch). Delivers locally if this
  # node is among the targets, and :ftl to the rest.
  defp dispatch_to_nodes(nodes, origin, pubsub, worker, topic, message, dispatcher) do
    self_node = node()

    # Single pass: drop the origin (it already delivered locally), flag whether this
    # node is itself a target, and collect the remote targets to :ftl.
    {local?, remote} =
      Enum.reduce(nodes, {false, []}, fn
        n, acc when n == origin -> acc
        n, {_local?, remote} when n == self_node -> {true, remote}
        n, {local?, remote} -> {local?, [n | remote]}
      end)

    if local? do
      RealtimeWeb.TenantBroadcaster.measure_broadcast_fanout(message)
      Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)
    end

    if remote != [] do
      Realtime.GenRpc.abcast(remote, worker, forward_to_local(topic, message, dispatcher), [])
    end

    :ok
  end
end
