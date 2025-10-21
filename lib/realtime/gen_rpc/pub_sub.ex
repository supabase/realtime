defmodule Realtime.GenRpcPubSub do
  @moduledoc """
  gen_rpc Phoenix.PubSub adapter
  """

  @behaviour Phoenix.PubSub.Adapter
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
  def broadcast(adapter_name, topic, message, dispatcher) do
    worker = worker_name(adapter_name, self())

    if Application.get_env(:realtime, :regional_broadcasting, false) do
      my_region = Application.get_env(:realtime, :region)
      # broadcast to all other nodes in the region

      other_nodes = for node <- Realtime.Nodes.region_nodes(my_region), node != node(), do: node
      GenRpc.abcast(other_nodes, worker, Worker.forward_to_local(topic, message, dispatcher), key: worker)

      # send a message to a node in each region to forward to the rest of the region
      other_region_nodes = nodes_from_other_regions(my_region, self())

      GenRpc.abcast(other_region_nodes, worker, Worker.forward_to_region(topic, message, dispatcher), key: worker)
    else
      GenRpc.abcast(Node.list(), worker, Worker.forward_to_local(topic, message, dispatcher), key: worker)
    end

    :ok
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
    GenRpc.abcast([node_name], worker, Worker.forward_to_local(topic, message, dispatcher), key: worker)
  end
end

defmodule Realtime.GenRpcPubSub.Worker do
  @moduledoc false
  use GenServer

  def forward_to_local(topic, message, dispatcher), do: {:ftl, topic, message, dispatcher}
  def forward_to_region(topic, message, dispatcher), do: {:ftr, topic, message, dispatcher}

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
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)
    {:noreply, {pubsub, worker}}
  end

  # Forward to the rest of the region
  def handle_info({:ftr, topic, message, dispatcher}, {pubsub, worker}) do
    # Forward to local first
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)

    # Then broadcast to the rest of my region
    my_region = Application.get_env(:realtime, :region)
    other_nodes = for node <- Realtime.Nodes.region_nodes(my_region), node != node(), do: node

    if other_nodes != [] do
      Realtime.GenRpc.abcast(other_nodes, worker, forward_to_local(topic, message, dispatcher), key: worker)
    end

    {:noreply, {pubsub, worker}}
  end

  @impl true
  def handle_info(_, pubsub), do: {:noreply, pubsub}
end
