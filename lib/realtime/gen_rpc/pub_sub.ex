defmodule Realtime.GenRpcPubSub do
  @moduledoc """
  gen_rpc Phoenix.PubSub adapter
  """

  @behaviour Phoenix.PubSub.Adapter
  alias Realtime.GenRpc
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
    GenRpc.abcast(Node.list(), worker, forward_to_local(topic, message, dispatcher), key: worker)
  end

  @impl true
  def direct_broadcast(adapter_name, node_name, topic, message, dispatcher) do
    worker = worker_name(adapter_name, self())
    GenRpc.abcast([node_name], worker, forward_to_local(topic, message, dispatcher), key: worker)
  end

  defp forward_to_local(topic, message, dispatcher), do: {:ftl, topic, message, dispatcher}
end

defmodule Realtime.GenRpcPubSub.Worker do
  @moduledoc false
  use GenServer

  @doc false
  def start_link({pubsub, worker}), do: GenServer.start_link(__MODULE__, pubsub, name: worker)

  @impl true
  def init(pubsub) do
    Process.flag(:message_queue_data, :off_heap)
    Process.flag(:fullsweep_after, 100)
    {:ok, pubsub}
  end

  @impl true
  def handle_info({:ftl, topic, message, dispatcher}, pubsub) do
    Phoenix.PubSub.local_broadcast(pubsub, topic, message, dispatcher)
    {:noreply, pubsub}
  end

  @impl true
  def handle_info(_, pubsub), do: {:noreply, pubsub}
end
