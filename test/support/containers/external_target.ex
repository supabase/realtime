defmodule Containers.ExternalTarget do
  @moduledoc false
  # Poolboy worker for one pre-configured external-tenant-DB port
  # (USE_EXTERNAL_TENANT_DB=true). Unlike Containers.Container, there's no
  # docker container to start or wait on — the port is already a live,
  # already-running Postgres-wire-compatible server; this worker just claims
  # one of the configured ports for the rest of its lifetime in the pool.
  use GenServer

  def start_link(args \\ [], opts \\ []) do
    GenServer.start_link(__MODULE__, args, opts)
  end

  def port(pid), do: GenServer.call(pid, :port, 15_000)

  @impl true
  def init(_args), do: {:ok, %{}, {:continue, :assign_port}}

  @impl true
  def handle_continue(:assign_port, _state) do
    port = Containers.start_external_target()
    {:noreply, %{port: port}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state[:port], state}
end
