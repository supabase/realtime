defmodule Realtime.ChannelProcessTracker do
  use GenServer

  require Logger

  @channel_mem_threshold 0.05

  # Client

  def start_link(default) do
    GenServer.start_link(__MODULE__, default, name: __MODULE__)
  end

  def check_memory() do
    GenServer.call(__MODULE__, :check_memory)
  end

  def track_transport_pid(pid) do
    GenServer.call(__MODULE__, {:add_transport_pid, pid})
  end

  # Server (callbacks)

  @impl true
  def init(_) do
    system_mem = :memsup.get_system_memory_data()

    threshold = @channel_mem_threshold * Keyword.fetch!(system_mem, :total_memory)

    # Logger.info("channel max total memory before gc: #{inspect(threshold)}")

    {:ok, %{threshold: threshold, pids: []}, {:continue, :get_channel_process_pids}}
  end

  @impl true
  def handle_continue(:get_channel_process_pids, %{pids: pids} = state) do
    new_pids =
      Enum.reduce(Process.list(), MapSet.new(pids), fn pid, acc ->
        case Process.info(pid, [:dictionary]) do
          [
            dictionary: [
              "$initial_call": {:cowboy_clear, :connection_process, 4},
              "$ancestors": _
            ]
          ] ->
            MapSet.put(acc, pid)

          _ ->
            acc
        end
      end)
      |> MapSet.to_list()

    # Logger.info("channel pids handle_continue: #{inspect(new_pids)}")

    {:noreply, %{state | pids: new_pids}}
  end

  @impl true
  def handle_call(:check_memory, _from, %{threshold: threshold, pids: pids} = state) do
    total_channel_mem =
      Enum.reduce(pids, 0, fn pid, acc ->
        case Process.info(pid, [:memory]) do
          [memory: memory] -> acc + memory
          _ -> acc
        end
      end)

    if total_channel_mem >= threshold do
      # Logger.info("channel total channel mem: #{inspect(total_channel_mem)}")
      # Enum.each(pids, &:erlang.garbage_collect/1)
      :timer.sleep(2)
    end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:add_transport_pid, pid}, _from, %{pids: pids} = state) do
    Process.monitor(pid)
    new_pids = MapSet.new(pids) |> MapSet.put(pid) |> MapSet.to_list()
    # Logger.info("newly joined pids: #{inspect(new_pids)}")
    {:reply, :ok, %{state | pids: new_pids}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{pids: pids} = state) do
    new_pids = MapSet.new(pids) |> MapSet.delete(pid) |> MapSet.to_list()
    # Logger.info("newly left pids: #{inspect(new_pids)}")
    {:noreply, %{state | pids: new_pids}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
