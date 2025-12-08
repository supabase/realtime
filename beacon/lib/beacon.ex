defmodule Beacon do

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
      raise ArgumentError, "expected :partitions to be a positive integer, got: #{inspect(partitions)}"
    end

    Beacon.Supervisor.start_link(scope, partitions)
  end

  @spec join(atom, term, pid) :: :ok
  def join(scope, group, pid) when is_atom(scope) and is_pid(pid) do
    Beacon.Partition.join(Beacon.Supervisor.partition(scope), group, pid)
  end

  @spec members(atom, term) :: [pid]
  def members(scope, group) when is_atom(scope) do
    Enum.flat_map(Beacon.Supervisor.partitions(scope), fn partition_name ->
      Beacon.Partition.members(partition_name, group)
    end)
  end

  @spec member_count(atom, term) :: non_neg_integer
  def member_count(scope, group) when is_atom(scope) do
    Enum.sum_by(Beacon.Supervisor.partitions(scope), fn partition_name ->
      Beacon.Partition.member_count(partition_name, group)
    end)
  end
end

defmodule Beacon.Supervisor do
  @moduledoc false
  use Supervisor

  def name(scope), do: :"#{scope}_beacon_supervisor"
  def table_name(scope), do: :"#{scope}_beacon_groups"
  def partition_name(scope, partition), do: :"#{scope}_beacon_partition_#{partition}"


  @spec partition(atom) :: atom
  def partition(scope) do
    case :persistent_term.get(scope, :unknown) do
      :unknown -> raise "Beacon for scope #{inspect(scope)} is not started"
      partition_names -> elem(partition_names, :erlang.phash2(self(), tuple_size(partition_names)))
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
    Supervisor.start_link(__MODULE__, arg, name: name(scope))
  end

  @impl true
  def init({scope, partitions}) do
    children =
      for i <- 0..(partitions - 1) do
        partition_name = partition_name(scope, i)
        ^partition_name = :ets.new(partition_name, [:set, :public, :named_table, read_concurrency: true])

        %{ id: i, start: {Beacon.Partition, :start_link, [partition_name]} }
      end

    partition_names = for i <- 0..(partitions - 1), do: partition_name(scope, i)

   :persistent_term.put(scope, List.to_tuple(partition_names))

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Beacon.Partition do
  @moduledoc "Beacon partitions FIXME"
  use GenServer

  @type group :: term

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{name: atom}
    defstruct [:name]
  end

  @spec join(atom, group, pid) :: :ok
  def join(partition_name, group, pid), do: GenServer.call(partition_name, {:join, group, pid})

  @spec members(atom, group) :: [pid]
  def members(partition_name, group) do
    case :ets.lookup_element(partition_name, group, 2, []) do
      [] -> []
      pids -> MapSet.to_list(pids)
    end
  end

  @spec member_count(atom, group) :: non_neg_integer
  def member_count(partition_name, group) do
    :ets.lookup_element(partition_name, group, 3, 0)
  end

  @spec start_link(atom) :: GenServer.on_start()
  def start_link(partition_name), do: GenServer.start_link(__MODULE__, partition_name, name: partition_name)

  @impl true
  @spec init(any) :: {:ok, State.t()}
  def init(name), do: {:ok, %State{name: name}}

  @impl true
  @spec handle_call({:join, group, pid}, GenServer.from(), State.t()) :: {:reply, :ok, State.t()}
  def handle_call({:join, group, pid}, _from, state) do
    case :ets.lookup(state.name, group) do
      [{^group, pids, counter}] ->
        new_pids = MapSet.put(pids, pid)
        :ets.insert(state.name, {group, new_pids, counter + 1})
        Process.monitor(pid, tag: {:DOWN, group})
        {:reply, :ok, state}
      [] ->
        :ets.insert(state.name, {group, MapSet.new([pid]), 1})
        Process.monitor(pid, tag: {:DOWN, group})
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_info({{:DOWN, group}, _ref, :process, pid, _reason}, state) do
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

    {:noreply, state}
  end

def handle_info(_, state), do: {:noreply, state}
end
