defmodule Realtime.Profiler do
  @moduledoc """
  Linux perf profiler
  """

  use GenServer

  defmodule State do
    defstruct [:port]
  end

  @spec start_link(any) :: GenServer.on_start()
  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @spec start() :: :ok | {:error, :already_running}
  def start, do: GenServer.call(__MODULE__, :start)

  @spec running?() :: boolean
  def running?, do: GenServer.call(__MODULE__, :running?)

  @impl true
  def init(_) do
    {:ok, %State{port: nil}}
  end

  @impl true
  def handle_call(:start, _from, %State{port: nil} = state) do
    # Run perf record -F 10000 -g -a --pid $BEAM_PID
    # System.cmd("perf", ["record", "-F", "10000", "-g", "-a", "--pid", "#{:os.getpid()}"], into: IO.stream(:stdio, :line))
    {tmp_path, 0} = System.cmd("mktemp", [])
    # Remove trailing newline
    tmp_path = String.trim(tmp_path)

    dbg(tmp_path)

    args = ["record", "-F", "1000", "-g", "-a", "--pid", "#{:os.getpid()}", "-o", tmp_path, "--", "sleep", "60"]
    cmd = Enum.join(["perf" | args], " ")

    # Open the port
    port = Port.open({:spawn, cmd}, [:exit_status]) |> dbg()
    {:reply, :ok, %{state | port: port}}
  end

  def handle_call(:start, _from, state), do: {:reply, {:error, :already_running}, state}

  def handle_call(:running?, _from, state), do: {:reply, is_port(state.port), state}

  @impl true
  def handle_info({port, {:exit_status, status}}, %State{port: port} = state) do
    dbg({:exit_status, status})
    {:noreply, %{state | port: nil}}
  end

  def handle_info(message, state) do
    dbg(message)
    {:noreply, state}
  end
end
