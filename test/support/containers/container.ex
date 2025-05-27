defmodule Containers.Container do
  use GenServer

  def start_link(args \\ [], opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  def port(pid), do: GenServer.call(pid, :port, 15_000)
  def name(pid), do: GenServer.call(pid, :name, 15_000)

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state[:port], state}
  end

  @impl true
  def handle_call(:name, _from, state) do
    {:reply, state[:name], state}
  end

  @impl true
  def init(_args) do
    {:ok, %{}, {:continue, :start_container}}
  end

  @impl true
  def handle_continue(:start_container, _state) do
    {:ok, name, port} = Containers.start_container()

    {:noreply, %{name: name, port: port}, {:continue, :check_container_ready}}
  end

  @impl true
  def handle_continue(:check_container_ready, state) do
    check_container_ready(state[:name])
    {:noreply, state}
  end

  defp check_container_ready(name, attempts \\ 100)
  defp check_container_ready(name, 0), do: raise("Container #{name} is not ready")

  defp check_container_ready(name, attempts) do
    case System.cmd("docker", ["exec", name, "pg_isready", "-p", "5432", "-h", "localhost"]) do
      {_, 0} ->
        :ok

      {_, _} ->
        Process.sleep(250)
        check_container_ready(name, attempts - 1)
    end
  end
end
