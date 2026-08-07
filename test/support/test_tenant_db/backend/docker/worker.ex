defmodule TestTenantDb.Backend.Docker.Worker do
  @moduledoc false
  # Poolboy worker for the Docker backend: claims a container from
  # TestTenantDb.Backend.Docker on start and waits for it to accept
  # connections before joining the pool.
  use GenServer

  alias TestTenantDb.Backend.Docker

  def start_link(args \\ [], opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  def port(pid), do: GenServer.call(pid, :port, 15_000)

  @impl true
  def init(_args), do: {:ok, %{}, {:continue, :claim}}

  @impl true
  def handle_continue(:claim, _state) do
    {:ok, name, port} = Docker.claim()
    {:noreply, %{name: name, port: port}, {:continue, :wait_ready}}
  end

  @impl true
  def handle_continue(:wait_ready, state) do
    Docker.wait_ready!(state.name)
    {:noreply, state}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state[:port], state}
end
