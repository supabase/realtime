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
    {:noreply, %{port: assign_port(10)}}
  end

  # A replacement worker (started by poolboy after a crash) can momentarily
  # find no port available if it asks before Containers has processed the
  # dead worker's :DOWN and reclaimed its port. Retry briefly instead of
  # crashing this worker outright.
  defp assign_port(attempts) do
    case Containers.start_external_target() do
      {:error, :no_external_ports_available} when attempts > 1 ->
        Process.sleep(100)
        assign_port(attempts - 1)

      {:error, :no_external_ports_available} ->
        raise "Containers.ExternalTarget: no external port became available after retrying"

      port ->
        port
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state[:port], state}
end
