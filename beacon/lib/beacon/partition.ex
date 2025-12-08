defmodule Beacon.Partition do
  @moduledoc false

  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            name: atom,
            scope: atom,
            monitors: %{{Beacon.group(), pid} => reference}
          }
    defstruct [:name, :scope, monitors: %{}]
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
  def groups(partition_name), do: :ets.select(partition_name, [{{:"$1", :_, :_}, [], [:"$1"]}])

  @spec group_count(atom) :: non_neg_integer
  def group_count(partition_name), do: :ets.info(partition_name, :size)

  @spec start_link(atom, atom) :: GenServer.on_start()
  def start_link(scope, partition_name),
    do: GenServer.start_link(__MODULE__, [scope, partition_name], name: partition_name)

  @impl true
  @spec init(any) :: {:ok, State.t()}
  def init([scope, name]) do
    {:ok, %State{scope: scope, name: name}, {:continue, :rebuild_monitors}}
  end

  @impl true
  @spec handle_continue(:rebuild_monitors, State.t()) :: {:noreply, State.t()}
  def handle_continue(:rebuild_monitors, state) do
    monitors =
      for {group, pids, _counter} <- :ets.tab2list(state.name), pid <- pids, into: %{} do
        ref = Process.monitor(pid, tag: {:DOWN, group})
        {{group, pid}, ref}
      end

    {:noreply, %{state | monitors: monitors}}
  end

  @impl true
  @spec handle_call({:join, Beacon.group(), pid}, GenServer.from(), State.t()) ::
          {:reply, :ok, State.t()}
  def handle_call({:join, group, pid}, _from, state) do
    case :ets.lookup(state.name, group) do
      [{^group, pids, counter}] ->
        if MapSet.member?(pids, pid) do
          # Already being tracked
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
    state = remove(group, pid, state)
    {:reply, :ok, state}
  end

  @impl true
  @spec handle_info({{:DOWN, Beacon.group()}, reference, :process, pid, term}, State.t()) ::
          {:noreply, State.t()}
  def handle_info({{:DOWN, group}, _ref, :process, pid, _reason}, state) do
    state = remove(group, pid, state)
    {:noreply, state}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp remove(group, pid, state) do
    case :ets.lookup(state.name, group) do
      [{^group, pids, counter}] ->
        if MapSet.member?(pids, pid) do
          new_pids = MapSet.delete(pids, pid)
          new_counter = counter - 1

          if new_counter == 0 do
            :ets.delete(state.name, group)
          else
            :ets.insert(state.name, {group, new_pids, new_counter})
          end
        else
          Logger.warning(
            "Beacon[#{node()}|#{state.scope}] Trying to remove an unknown process #{inspect(pid)}"
          )
        end

      [] ->
        :ok
    end

    case Map.pop(state.monitors, {group, pid}) do
      {nil, _} ->
        state

      {ref, new_monitors} ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: new_monitors}
    end
  end
end
