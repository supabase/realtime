defmodule Beacon.Scope do
  @moduledoc false
  # Responsible to discover and keep track of all Beacon peers in the cluster

  use GenServer
  require Logger

  @default_broadcast_interval 5_000

  @spec member_counts(atom) :: %{Beacon.group() => non_neg_integer}
  def member_counts(scope) do
    scope
    |> table_name()
    |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
    |> Enum.reduce(%{}, fn member_counts, acc ->
      Map.merge(acc, member_counts, fn _k, v1, v2 -> v1 + v2 end)
    end)
  end

  @spec member_count(atom, Beacon.group()) :: non_neg_integer
  def member_count(scope, group) do
    scope
    |> table_name()
    |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
    |> Enum.sum_by(fn member_counts -> Map.get(member_counts, group, 0) end)
  end

  @spec member_count(atom, Beacon.group(), node) :: non_neg_integer
  def member_count(scope, group, node) do
    case :ets.lookup(table_name(scope), node) do
      [{^node, member_counts}] -> Map.get(member_counts, group, 0)
      [] -> 0
    end
  end

  @spec groups(atom) :: MapSet.t(Beacon.group())
  def groups(scope) do
    scope
    |> table_name()
    |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
    |> Enum.reduce(MapSet.new(), fn member_counts, acc ->
      member_counts
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(acc)
    end)
  end

  @typep member_counts :: %{Beacon.group() => non_neg_integer}

  defp table_name(scope), do: :"#{scope}_beacon_peer_counts"

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            scope: atom,
            message_module: module,
            broadcast_interval: non_neg_integer,
            peer_counts_table: :ets.tid(),
            peers: %{pid => reference}
          }
    defstruct [
      :scope,
      :message_module,
      :broadcast_interval,
      :peer_counts_table,
      peers: %{}
    ]
  end

  @spec start_link(atom, Keyword.t()) :: GenServer.on_start()
  def start_link(scope, opts \\ []), do: GenServer.start_link(__MODULE__, [scope, opts])

  @impl true
  def init([scope, opts]) do
    :ok = :net_kernel.monitor_nodes(true)

    peer_counts_table =
      :ets.new(table_name(scope), [:set, :protected, :named_table, read_concurrency: true])

    broadcast_interval =
      Keyword.get(opts, :broadcast_interval_in_ms, @default_broadcast_interval)

    message_module = Keyword.get(opts, :message_module, Beacon.Adapter.ErlDist)

    Logger.info("Beacon[#{node()}|#{scope}] Starting")

    :ok = message_module.register(scope)

    {:ok,
     %State{
       scope: scope,
       message_module: message_module,
       broadcast_interval: broadcast_interval,
       peer_counts_table: peer_counts_table
     }, {:continue, :discover}}
  end

  @impl true
  @spec handle_continue(:discover, State.t()) :: {:noreply, State.t()}
  def handle_continue(:discover, state) do
    state.message_module.broadcast(state.scope, {:discover, self()})
    Process.send_after(self(), :broadcast_counts, state.broadcast_interval)
    {:noreply, state}
  end

  @impl true
  @spec handle_info(
          {:discover, pid}
          | {:sync, pid, member_counts}
          | :broadcast_counts
          | {:nodeup, node}
          | {:nodedown, node}
          | {:DOWN, reference, :process, pid, term},
          State.t()
        ) :: {:noreply, State.t()}
  # A remote peer is discovering us
  def handle_info({:discover, peer}, state) do
    Logger.info(
      "Beacon[#{node()}|#{state.scope}] Received DISCOVER request from node #{node(peer)}"
    )

    state.message_module.send(
      state.scope,
      node(peer),
      {:sync, self(), Beacon.local_member_counts(state.scope)}
    )

    # We don't do anything if we already know about this peer
    if Map.has_key?(state.peers, peer) do
      Logger.debug(
        "Beacon[#{node()}|#{state.scope}] already know peer #{inspect(peer)} from node #{node(peer)}"
      )

      {:noreply, state}
    else
      Logger.debug(
        "Beacon[#{node()}|#{state.scope}] discovered peer #{inspect(peer)} from node #{node(peer)}"
      )

      ref = Process.monitor(peer)
      new_peers = Map.put(state.peers, peer, ref)
      state.message_module.send(state.scope, node(peer), {:discover, self()})
      {:noreply, %State{state | peers: new_peers}}
    end
  end

  # A remote peer has sent us its local member counts
  def handle_info({:sync, peer, member_counts}, state) do
    :ets.insert(state.peer_counts_table, {node(peer), member_counts})
    {:noreply, state}
  end

  # Periodic broadcast of our local member counts to all known peers
  def handle_info(:broadcast_counts, state) do
    nodes =
      state.peers
      |> Map.keys()
      |> Enum.map(&node/1)

    state.message_module.broadcast(
      state.scope,
      nodes,
      {:sync, self(), Beacon.local_member_counts(state.scope)}
    )

    Process.send_after(self(), :broadcast_counts, state.broadcast_interval)
    {:noreply, state}
  end

  # Do nothing if the node that came up is our own node
  def handle_info({:nodeup, node}, state) when node == node(), do: {:noreply, state}

  # Send a discover message to the node that just connected
  def handle_info({:nodeup, node}, state) do
    :telemetry.execute([:beacon, state.scope, :node, :up], %{}, %{node: node})

    Logger.info(
      "Beacon[#{node()}|#{state.scope}] Node #{node} has joined the cluster, sending discover message"
    )

    state.message_module.send(state.scope, node, {:discover, self()})
    {:noreply, state}
  end

  # Do nothing and wait for the DOWN message from monitor
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  # A remote peer has disconnected/crashed
  # We forget about it and remove its member counts
  def handle_info({:DOWN, ref, :process, peer, reason}, state) do
    Logger.info(
      "Beacon[#{node()}|#{state.scope}] Scope process is DOWN on node #{node(peer)}: #{inspect(reason)}"
    )

    case Map.pop(state.peers, peer) do
      {nil, _} ->
        {:noreply, state}

      {^ref, new_peers} ->
        :ets.delete(state.peer_counts_table, node(peer))
        :telemetry.execute([:beacon, state.scope, :node, :down], %{}, %{node: node(peer)})
        {:noreply, %State{state | peers: new_peers}}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
