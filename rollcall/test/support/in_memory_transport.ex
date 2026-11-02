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
  """

  @behaviour Rollcall.Transport

  alias Rollcall.Transport.InMemory.Network

  @impl true
  def init(scope, opts) do
    network = Keyword.fetch!(opts, :network)
    node = Keyword.fetch!(opts, :node)

    :ok = Network.join(network, scope, self())
    {:ok, %{network: network, scope: scope, node: node}}
  end

  @impl true
  def heartbeat(%{network: network, scope: scope, node: node}, message) do
    Network.broadcast(network, scope, self(), node, message)
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

  It holds the pids that joined each scope. `broadcast/5` returns after the
  network put the message in the mailbox of each recipient. A test can then wait
  for the recipient with `:sys.get_state/1`.

  `drop_next/2` makes the network discard the next deliveries. The count is for
  deliveries, so a broadcast to two recipients uses two.
  """

  use GenServer

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, :ok, opts)

  @doc "Adds `pid` to the members of `scope`."
  @spec join(GenServer.server(), term(), pid()) :: :ok
  def join(network, scope, pid), do: GenServer.call(network, {:join, scope, pid})

  @doc "Sends `message` from `from` on `node` to every other member of `scope`."
  @spec broadcast(GenServer.server(), term(), pid(), node(), term()) :: :ok
  def broadcast(network, scope, from, node, message) do
    GenServer.call(network, {:broadcast, scope, from, node, message})
  end

  @doc "Discards the next `count` deliveries."
  @spec drop_next(GenServer.server(), pos_integer()) :: :ok
  def drop_next(network, count \\ 1), do: GenServer.call(network, {:drop_next, count})

  @impl true
  def init(:ok), do: {:ok, %{members: %{}, monitors: %{}, drops: 0}}

  @impl true
  def handle_call({:join, scope, pid}, _from, state) do
    state = ensure_monitor(state, pid)
    members = Map.update(state.members, scope, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{state | members: members}}
  end

  def handle_call({:broadcast, scope, from, node, message}, _from, state) do
    recipients = state.members |> Map.get(scope, MapSet.new()) |> MapSet.delete(from)

    state =
      Enum.reduce(recipients, state, fn pid, state ->
        deliver(state, pid, {:in_memory, scope, node, message})
      end)

    {:reply, :ok, state}
  end

  def handle_call({:drop_next, count}, _from, state) do
    {:reply, :ok, %{state | drops: state.drops + count}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    members = Map.new(state.members, fn {scope, pids} -> {scope, MapSet.delete(pids, pid)} end)
    {:noreply, %{state | members: members, monitors: Map.delete(state.monitors, pid)}}
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
