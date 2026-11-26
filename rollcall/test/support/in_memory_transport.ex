defmodule Rollcall.Transport.InMemory do
  @moduledoc """
  A transport for tests. Trackers in one VM exchange messages through a
  `Rollcall.Transport.InMemory.Network` process.

  The options of `init/2` are `:network`, the pid of the network, and `:node`,
  the node name of the joining tracker. All pids in one VM have the node
  `node()`. `unwrap/2` therefore rewrites the origin of a message to a pid on
  the node of the sender. The tracker then finds a separate peer record for
  each sender, as it does in a cluster.

  The network never delivers a message to its sender.

  `send_to/3` delivers a message to the trackers of the scope on one fake node.

  `publish/3` delivers a diff to the processes that subscribed to the
  partition on the node of the tracker. Use `Network.subscribe/5`. A subscriber
  gets `{:rollcall_diff, scope, partition, diff}`.
  """

  @behaviour Rollcall.Transport

  alias Rollcall.Transport.InMemory.Network

  @impl true
  def init(scope, opts) do
    network = Keyword.fetch!(opts, :network)
    node = Keyword.fetch!(opts, :node)

    :ok = Network.join(network, scope, self(), node)
    {:ok, %{network: network, scope: scope, node: node}}
  end

  @impl true
  def heartbeat(%{network: network, scope: scope, node: node}, message) do
    Network.broadcast(network, scope, self(), node, message)
  end

  @impl true
  def send_to(%{network: network, scope: scope, node: node}, to_node, message) do
    Network.send_to(network, scope, node, to_node, message)
  end

  @impl true
  def publish(%{network: network, scope: scope, node: node}, partition, diff) do
    Network.publish(network, node, scope, partition, diff)
  end

  @impl true
  def unwrap(_transport, {:in_memory, scope, node, message}) do
    origin = elem(message, 1)
    {:ok, scope, put_elem(message, 1, remote_origin(node, origin))}
  end

  def unwrap(_transport, _raw), do: :ignore

  # A restarted tracker has a new pid on the same node. The id comes from the
  # real pid, so each tracker gets its own origin.
  defp remote_origin(node, origin) do
    Rollcall.TrackerHelpers.remote_pid(node, :erlang.phash2(origin, 4_294_967_295) + 1)
  end
end

defmodule Rollcall.Transport.InMemory.Network do
  @moduledoc """
  The process that connects the trackers of `Rollcall.Transport.InMemory`.

  It holds the pids that joined each scope, and the fake node of each pid.
  `broadcast/5` and `send_to/5` return after the network put the message in the
  mailbox of each recipient. A test can then wait for the recipient with
  `:sys.get_state/1`.

  It also holds the subscribers of each partition on each node. `publish/5`
  returns after the network put the diff in the mailbox of each subscriber of
  that node, scope and partition. Drops do not apply to publications.

  `drop_next/2` makes the network discard the next deliveries. The count is for
  deliveries, so a broadcast to two recipients uses two.
  """

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, opts)

  @doc "Adds `pid` to the members of `scope`, as a process on the fake node `node`."
  @spec join(GenServer.server(), term(), pid(), node()) :: :ok
  def join(network, scope, pid, node), do: GenServer.call(network, {:join, scope, pid, node})

  @doc "Sends `message` from `from` on `node` to every other member of `scope`."
  @spec broadcast(GenServer.server(), term(), pid(), node(), term()) :: :ok
  def broadcast(network, scope, from, node, message) do
    GenServer.call(network, {:broadcast, scope, from, node, message})
  end

  @doc "Sends `message` from the fake node `from_node` to the members of `scope` on the fake node `to_node`."
  @spec send_to(GenServer.server(), term(), node(), node(), term()) :: :ok
  def send_to(network, scope, from_node, to_node, message) do
    GenServer.call(network, {:send_to, scope, from_node, to_node, message})
  end

  @doc "Adds `pid` to the subscribers of `partition` of `scope` on `node`."
  @spec subscribe(GenServer.server(), node(), term(), term(), pid()) :: :ok
  def subscribe(network, node, scope, partition, pid) do
    GenServer.call(network, {:subscribe, node, scope, partition, pid})
  end

  @doc "Sends `diff` to the subscribers of `partition` of `scope` on `node`."
  @spec publish(GenServer.server(), node(), term(), term(), term()) :: :ok
  def publish(network, node, scope, partition, diff) do
    GenServer.call(network, {:publish, node, scope, partition, diff})
  end

  @doc "Discards the next `count` deliveries."
  @spec drop_next(GenServer.server(), pos_integer()) :: :ok
  def drop_next(network, count \\ 1), do: GenServer.call(network, {:drop_next, count})

  @doc "Cancels the deliveries that `drop_next/2` has not used yet."
  @spec clear_drops(GenServer.server()) :: :ok
  def clear_drops(network), do: GenServer.call(network, :clear_drops)

  @impl true
  def init(:ok), do: {:ok, %{members: %{}, nodes: %{}, subscribers: %{}, monitors: %{}, drops: 0}}

  @impl true
  def handle_call({:join, scope, pid, node}, _from, state) do
    state = ensure_monitor(state, pid)
    members = Map.update(state.members, scope, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{state | members: members, nodes: Map.put(state.nodes, pid, node)}}
  end

  def handle_call({:broadcast, scope, from, node, message}, _from, state) do
    recipients = state.members |> Map.get(scope, MapSet.new()) |> MapSet.delete(from)

    state =
      Enum.reduce(recipients, state, fn pid, state ->
        deliver(state, pid, {:in_memory, scope, node, message})
      end)

    {:reply, :ok, state}
  end

  def handle_call({:send_to, scope, from_node, to_node, message}, _from, state) do
    recipients =
      state.members
      |> Map.get(scope, MapSet.new())
      |> Enum.filter(fn pid -> Map.get(state.nodes, pid) == to_node end)

    state =
      Enum.reduce(recipients, state, fn pid, state ->
        deliver(state, pid, {:in_memory, scope, from_node, message})
      end)

    {:reply, :ok, state}
  end

  def handle_call({:subscribe, node, scope, partition, pid}, _from, state) do
    state = ensure_monitor(state, pid)
    subscribers = Map.update(state.subscribers, {node, scope, partition}, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{state | subscribers: subscribers}}
  end

  def handle_call({:publish, node, scope, partition, diff}, _from, state) do
    for pid <- Map.get(state.subscribers, {node, scope, partition}, MapSet.new()) do
      send(pid, {:rollcall_diff, scope, partition, diff})
    end

    {:reply, :ok, state}
  end

  def handle_call({:drop_next, count}, _from, state) do
    {:reply, :ok, %{state | drops: state.drops + count}}
  end

  def handle_call(:clear_drops, _from, state) do
    {:reply, :ok, %{state | drops: 0}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    members = Map.new(state.members, fn {scope, pids} -> {scope, MapSet.delete(pids, pid)} end)
    subscribers = Map.new(state.subscribers, fn {key, pids} -> {key, MapSet.delete(pids, pid)} end)

    {:noreply,
     %{
       state
       | members: members,
         nodes: Map.delete(state.nodes, pid),
         subscribers: subscribers,
         monitors: Map.delete(state.monitors, pid)
     }}
  end

  defp deliver(%{drops: drops} = state, _pid, _raw) when drops > 0, do: %{state | drops: drops - 1}

  defp deliver(state, pid, raw) do
    send(pid, raw)
    state
  end

  defp ensure_monitor(%{monitors: monitors} = state, pid) do
    if Map.has_key?(monitors, pid) do
      state
    else
      %{state | monitors: Map.put(monitors, pid, Process.monitor(pid))}
    end
  end
end
