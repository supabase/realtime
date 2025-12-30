defmodule Beacon.Partition do
  @moduledoc false

  use GenServer
  require Logger

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            name: atom,
            scope: atom,
            entries_table: atom,
            monitors: %{{Beacon.group(), pid} => reference}
          }
    defstruct [:name, :scope, :entries_table, monitors: %{}]
  end

  @spec join(atom, Beacon.group(), pid) :: :ok
  def join(partition_name, group, pid), do: GenServer.call(partition_name, {:join, group, pid})

  @spec leave(atom, Beacon.group(), pid) :: :ok
  def leave(partition_name, group, pid), do: GenServer.call(partition_name, {:leave, group, pid})

  @spec members(atom, Beacon.group()) :: [pid]
  def members(partition_name, group) do
    partition_name
    |> Beacon.Supervisor.partition_entries_table()
    |> :ets.select([{{{group, :"$1"}}, [], [:"$1"]}])
  end

  @spec member_count(atom, Beacon.group()) :: non_neg_integer
  def member_count(partition_name, group), do: :ets.lookup_element(partition_name, group, 2, 0)

  @spec member_counts(atom) :: %{Beacon.group() => non_neg_integer}
  def member_counts(partition_name) do
    partition_name
    |> :ets.tab2list()
    |> Map.new()
  end

  @spec member?(atom, Beacon.group(), pid) :: boolean
  def member?(partition_name, group, pid) do
    partition_name
    |> Beacon.Supervisor.partition_entries_table()
    |> :ets.lookup({group, pid})
    |> case do
      [{{^group, ^pid}}] -> true
      [] -> false
    end
  end

  @spec groups(atom) :: [Beacon.group()]
  def groups(partition_name), do: :ets.select(partition_name, [{{:"$1", :_}, [], [:"$1"]}])

  @spec group_count(atom) :: non_neg_integer
  def group_count(partition_name), do: :ets.info(partition_name, :size)

  @spec start_link(atom, atom, atom) :: GenServer.on_start()
  def start_link(scope, partition_name, partition_entries_table),
    do:
      GenServer.start_link(__MODULE__, [scope, partition_name, partition_entries_table],
        name: partition_name
      )

  @impl true
  @spec init(any) :: {:ok, State.t()}
  def init([scope, name, entries_table]) do
    {:ok, %State{scope: scope, name: name, entries_table: entries_table},
     {:continue, :rebuild_monitors_and_counters}}
  end

  @impl true
  @spec handle_continue(:rebuild_monitors_and_counters, State.t()) :: {:noreply, State.t()}
  def handle_continue(:rebuild_monitors_and_counters, state) do
    # Here we delete all counters and rebuild them based on entries table
    :ets.delete_all_objects(state.name)

    monitors =
      :ets.tab2list(state.entries_table)
      |> Enum.reduce(%{}, fn {{group, pid}}, monitors_acc ->
        ref = Process.monitor(pid, tag: {:DOWN, group})
        :ets.update_counter(state.name, group, {2, 1}, {group, 0})
        Map.put(monitors_acc, {group, pid}, ref)
      end)

    {:noreply, %{state | monitors: monitors}}
  end

  @impl true
  @spec handle_call({:join, Beacon.group(), pid}, GenServer.from(), State.t()) ::
          {:reply, :ok, State.t()}
  def handle_call({:join, group, pid}, _from, state) do
    if :ets.insert_new(state.entries_table, {{group, pid}}) do
      # Increment existing or create
      :ets.update_counter(state.name, group, {2, 1}, {group, 0})
      ref = Process.monitor(pid, tag: {:DOWN, group})
      monitors = Map.put(state.monitors, {group, pid}, ref)
      {:reply, :ok, %{state | monitors: monitors}}
    else
      {:reply, :ok, state}
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
    case :ets.lookup(state.entries_table, {group, pid}) do
      [{{^group, ^pid}}] ->
        :ets.delete(state.entries_table, {group, pid})

        # Delete or decrement counter
        case :ets.lookup_element(state.name, group, 2, 0) do
          1 -> :ets.delete(state.name, group)
          count when count > 1 -> :ets.update_counter(state.name, group, {2, -1})
        end

      [] ->
        Logger.warning(
          "Beacon[#{node()}|#{state.scope}] Trying to remove an unknown process #{inspect(pid)}"
        )

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
