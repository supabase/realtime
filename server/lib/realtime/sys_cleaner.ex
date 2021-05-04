defmodule Realtime.SysCleaner do
  use GenServer

  require Logger

  @timeout 10_000
  @threshold 75

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    {:ok, %{}, @timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    if ram_usage() > @threshold do
      Logger.warning("Try clean VM")
      clean_all_mem()
    end
    {:noreply, state, @timeout}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("Undefined message: #{inspect(msg)}")
    {:noreply, state, @timeout}
  end

  def clean_all_mem() do
    _ = for pid <- Process.list, do: :erlang.garbage_collect(pid)
  end 

  def ram_usage() do
    mem = :memsup.get_system_memory_data()
    total = case :os.type() do
      {_, :darwin} ->
        {res, _} = System.cmd("sysctl", ["-n", "hw.memsize"])
        {mem, _} = Integer.parse(res)
        mem
      _ -> mem[:total_memory]
    end

    cached = case mem[:cached_memory] do
      nil -> 0
      val -> val
    end

    free = mem[:free_memory] + cached
    100 - free / total * 100
  end

end
