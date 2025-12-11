defmodule Beacon.Adapter do
  @callback register(scope :: atom) :: any
  @callback broadcast(scope :: atom, message :: term) :: any
  @callback send(scope :: atom, [node], message :: term) :: any
end

# defmodule Beacon.PubSub do
#   import Kernel, except: [send: 2]
#
#   @behaviour Beacon.Adapter
#
#   def register(scope), do: Phoenix.PubSub.subscribe(Realtime.PubSub, "beacon:" <> scope)
#
#   def broadcast(scope, message) do
#       Phoenix.PubSub.broadcast(
#         Realtime.PubSub,
#         "beacon:" <> scope,
#         message
#       )
#   end
#
#   def send(scope, nodes, message) do
#     Enum.each(nodes, fn node ->
#       Phoenix.PubSub.broadcast(
#         Realtime.PubSub,
#         node,
#         "beacon:" <> scope,
#         message
#       )
#     end)
#   end
# end

defmodule Beacon.ErlDist do
  import Kernel, except: [send: 2]

  @behaviour Beacon.Adapter

  def register(_scope), do: :ok

  def broadcast(scope, message) do
    name = Beacon.Supervisor.name(scope)
    Enum.each(Node.list(), fn node -> :erlang.send({name, node}, message, [:noconnect]) end)
  end

  def send(scope, node, message) do
    :erlang.send({Beacon.Supervisor.name(scope), node}, message, [:noconnect])
  end
end

defmodule Beacon do
  @moduledoc """
  FIXME
  """

  alias Beacon.Partition

  @type group :: term
  @type start_option :: {:partitions, pos_integer()}

  @doc """
  Starts the Beacon supervision tree.

  Options:

  * `:partitions` - number of partitions to use (default: number of schedulers online)
  """
  @spec start_link(atom, start_option) :: Supervisor.on_start()
  def start_link(scope, opts \\ []) when is_atom(scope) do
    partitions = Keyword.get(opts, :partitions, System.schedulers_online())

    if not (is_integer(partitions) and partitions >= 1) do
      raise ArgumentError,
            "expected :partitions to be a positive integer, got: #{inspect(partitions)}"
    end

    Beacon.Supervisor.start_link(scope, partitions)
  end

  @spec join(atom, group, pid) :: :ok
  def join(scope, group, pid) when is_atom(scope) and is_pid(pid) do
    Partition.join(Beacon.Supervisor.partition(scope, group), group, pid)
  end

  def leave(scope, group, pid) when is_atom(scope) and is_pid(pid) do
    Partition.leave(Beacon.Supervisor.partition(scope, group), group, pid)
  end

  @spec member_counts(atom) :: %{group => non_neg_integer}
  def member_counts(scope) when is_atom(scope) do
    remote_counts = Beacon.Scope.member_counts(scope)

    scope
    |> local_member_counts()
    |> Map.merge(remote_counts, fn _k, v1, v2 -> v1 + v2 end)
  end

  @spec local_members(atom, group) :: [pid]
  def local_members(scope, group) when is_atom(scope) do
    Partition.members(Beacon.Supervisor.partition(scope, group), group)
  end

  @spec local_member_count(atom, group) :: non_neg_integer
  def local_member_count(scope, group) when is_atom(scope) do
    Beacon.Partition.member_count(Beacon.Supervisor.partition(scope, group), group)
  end

  @spec local_member_counts(atom) :: %{group => non_neg_integer}
  def local_member_counts(scope) when is_atom(scope) do
    Enum.reduce(Beacon.Supervisor.partitions(scope), %{}, fn partition_name, acc ->
      Map.merge(acc, Beacon.Partition.member_counts(partition_name))
    end)
  end

  @spec local_member?(atom, group, pid) :: boolean
  def local_member?(scope, group, pid) when is_atom(scope) and is_pid(pid) do
    Beacon.Partition.member?(Beacon.Supervisor.partition(scope, group), group, pid)
  end

  @spec local_groups(atom) :: [group]
  def local_groups(scope) do
    Enum.flat_map(Beacon.Supervisor.partitions(scope), fn partition_name ->
      Partition.groups(partition_name)
    end)
  end
end

defmodule Beacon.Scope do
  use GenServer

  def member_counts(scope) do
    scope
    |> table_name()
    |> :ets.select([{{:_, :"$1"}, [], [:"$1"]}])
    |> Enum.reduce(%{}, fn member_counts, acc ->
      Map.merge(acc, member_counts, fn _k, v1, v2 -> v1 + v2 end)
    end)
  end

  @typep member_counts :: %{Beacon.group() => non_neg_integer}

  defp table_name(scope), do: :"#{scope}_beacon_peer_counts"

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            scope: atom,
            message_module: module,
            peer_counts_table: :ets.tid(),
            peers: %{pid => reference}
          }
    defstruct [:scope, :message_module, :peer_counts_table, peers: %{}]
  end

  def start_link(name, scope), do: GenServer.start_link(__MODULE__, [scope], name: name)

  @impl true
  def init([scope]) do
    :ok = :net_kernel.monitor_nodes(true)

    peer_counts_table =
      :ets.new(table_name(scope), [:set, :protected, :named_table, read_concurrency: true])

    {:ok,
     %State{scope: scope, message_module: Beacon.ErlDist, peer_counts_table: peer_counts_table},
     {:continue, :discover}}
  end

  @impl true
  @spec handle_continue(:discover, State.t()) :: {:noreply, State.t()}
  def handle_continue(:discover, state) do
    state.message_module.broadcast(state.scope, {:discover, self()})
    {:noreply, state}
  end

  @impl true
  @spec handle_info(
          {:discover, pid}
          | {:sync, pid, member_counts}
          | {:nodeup, node}
          | {:nodedown, node}
          | {:DOWN, reference, :process, pid, term},
          State.t()
        ) :: {:noreply, State.t()}
  def handle_info({:discover, peer}, state) do
    state.message_module.send(
      state.scope,
      node(peer),
      {:sync, self(), Beacon.local_member_counts(state.scope)}
    )

    # We don't do anything if we already know about this peer
    if Map.has_key?(state.peers, peer) do
      {:noreply, state}
    else
      ref = Process.monitor(peer)
      new_peers = Map.put(state.peers, peer, ref)
      state.message_module.send(state.scope, node(peer), {:discover, self()})
      {:noreply, %State{state | peers: new_peers}}
    end
  end

  # Do nothing and wait for the DOWN message from monitor
  def handle_info({:nodedown, _node}, state), do: {:noreply, state}

  def handle_info({:nodeup, node}, state) when node == node(), do: {:noreply, state}

  def handle_info({:nodeup, node}, state) do
    state.message_module.send(state.scope, node, {:discover, self()})
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, peer, _reason}, state) do
    case Map.pop(state.peers, peer) do
      {nil, _} ->
        {:noreply, state}

      {^ref, new_peers} ->
        :ets.delete(state.peer_counts_table, node(peer))
        {:noreply, %State{state | peers: new_peers}}
    end
  end

  def handle_info({:sync, peer, member_counts}, state) do
    :ets.insert(state.peer_counts_table, {node(peer), member_counts})
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end

defmodule Beacon.Supervisor do
  @moduledoc false
  use Supervisor

  def name(scope), do: :"#{scope}_beacon"
  def supervisor_name(scope), do: :"#{scope}_beacon_supervisor"
  def partition_name(scope, partition), do: :"#{scope}_beacon_partition_#{partition}"

  @spec partition(atom, pid) :: atom
  def partition(scope, pid) do
    case :persistent_term.get(scope, :unknown) do
      :unknown -> raise "Beacon for scope #{inspect(scope)} is not started"
      partition_names -> elem(partition_names, :erlang.phash2(pid, tuple_size(partition_names)))
    end
  end

  @spec partitions(atom) :: [atom]
  def partitions(scope) do
    case :persistent_term.get(scope, :unknown) do
      :unknown -> raise "Beacon for scope #{inspect(scope)} is not started"
      partition_names -> Tuple.to_list(partition_names)
    end
  end

  @spec start_link(atom, pos_integer()) :: Supervisor.on_start()
  def start_link(scope, partitions) do
    arg = {scope, partitions}
    Supervisor.start_link(__MODULE__, arg, name: supervisor_name(scope))
  end

  @impl true
  def init({scope, partitions}) do
    children =
      for i <- 0..(partitions - 1) do
        partition_name = partition_name(scope, i)

        ^partition_name =
          :ets.new(partition_name, [:set, :public, :named_table, read_concurrency: true])

        %{id: i, start: {Beacon.Partition, :start_link, [partition_name]}}
      end

    partition_names = for i <- 0..(partitions - 1), do: partition_name(scope, i)

    :persistent_term.put(scope, List.to_tuple(partition_names))

    children = [
      %{id: :scope, start: {Beacon.Scope, :start_link, [name(scope), scope]}} | children
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Beacon.Partition do
  @moduledoc false
  use GenServer

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{name: atom, monitors: %{{group, pid} => ref}}
    defstruct [:name, monitors: %{}]
  end

  @spec join(atom, Beacon.group(), pid) :: :ok
  def join(partition_name, group, pid), do: GenServer.call(partition_name, {:join, group, pid})

  @spec leave(atom, Beacon.group(), pid) :: :ok
  def leave(partition_name, group, pid), do: GenServer.call(partition_name, {:leave, group, pid})

  @spec members(atom, Beacon.group()) :: [pid]
  def members(partition_name, group) do
    case :ets.lookup_element(partition_name, group, 2, []) do
      [] -> []
      pids -> MapSet.to_list(pids)
    end
  end

  @spec member_count(atom, Beacon.group()) :: non_neg_integer
  def member_count(partition_name, group), do: :ets.lookup_element(partition_name, group, 3, 0)

  @spec member_counts(atom) :: %{Beacon.group() => non_neg_integer}
  def member_counts(partition_name) do
    partition_name
    |> :ets.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> Map.new()
  end

  @spec member?(atom, Beacon.group(), pid) :: boolean
  def member?(partition_name, group, pid) do
    case :ets.lookup_element(partition_name, group, 2, []) do
      [] -> false
      pids -> MapSet.member?(pids, pid)
    end
  end

  @spec groups(atom) :: [Beacon.group()]
  def groups(partition_name) do
    :ets.select(partition_name, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end

  @spec start_link(atom) :: GenServer.on_start()
  def start_link(partition_name),
    do: GenServer.start_link(__MODULE__, partition_name, name: partition_name)

  @impl true
  @spec init(any) :: {:ok, State.t()}
  def init(name), do: {:ok, %State{name: name}}

  @impl true
  @spec handle_call({:join, Beacon.group(), pid}, GenServer.from(), State.t()) ::
          {:reply, :ok, State.t()}
  def handle_call({:join, group, pid}, _from, state) do
    case :ets.lookup(state.name, group) do
      [{^group, pids, counter}] ->
        if MapSet.member?(pids, pid) do
          {:reply, :ok, state}
        else
          new_pids = MapSet.put(pids, pid)
          :ets.insert(state.name, {group, new_pids, counter + 1})
          ref = Process.monitor(pid, tag: {:DOWN, group})
          monitors = Map.put(state.monitors, {group, pid}, ref)
          {:reply, :ok, %{state | monitors: monitors}}
        end

      [] ->
        :ets.insert(state.name, {group, MapSet.new([pid]), 1})
        ref = Process.monitor(pid, tag: {:DOWN, group})
        monitors = Map.put(state.monitors, {group, pid}, ref)
        {:reply, :ok, %{state | monitors: monitors}}
    end
  end

  def handle_call({:leave, group, pid}, _from, state) do
    state = remove(group, pid, state.name)
    {:reply, :ok, state}
  end

  @impl true
  @spec handle_info({{:DOWN, Beacon.group()}, reference, :process, pid, term}, State.t()) ::
          {:noreply, State.t()}
  def handle_info({{:DOWN, group}, ref, :process, pid, _reason}, state) do
    state = remove(group, pid, state)
    {:noreply, state}
  end

 defp remove(group, pid, state) do
    case :ets.lookup(state.name, group) do
      [{^group, pids, counter}] ->
        # This should not be possible but we account for this anyway
        if MapSet.member?(pids, pid) do
          new_pids = MapSet.delete(pids, pid)
          new_counter = counter - 1

          if new_counter == 0 do
            :ets.delete(state.name, group)
          else
            :ets.insert(state.name, {group, new_pids, new_counter})
          end
        end

      [] ->
        :ok
    end

    case Map.pop(state.monitors, {group, pid}) do
      {nil, _} -> state
      {ref, new_monitors} ->
        Process.demonitor(ref, [:flush])
      %{state | monitors: new_monitors}
    end
 end

  def handle_info(_, state), do: {:noreply, state}
end
