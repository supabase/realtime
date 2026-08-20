defmodule Realtime.RegionMembership do
  @moduledoc """
  Owns this node's membership of the syn `RegionNodes` group.

  Started last in `Realtime.Application` so this node is only advertised once the
  rest of the tree can serve the work it will be handed. `leave/0` withdraws it on
  shutdown so peers stop picking it for new work.
  """
  use GenServer
  require Logger

  alias Realtime.SignalHandler

  def start_link(region), do: GenServer.start_link(__MODULE__, region, name: __MODULE__)

  @doc """
  Removes this node from the `RegionNodes` group.

  Never raises or exits: it runs inside the SIGTERM handler, and a failure there
  would stop the node from ever reaching `init:stop/0`.
  """
  @spec leave() :: :ok
  def leave do
    GenServer.call(__MODULE__, :leave)
  catch
    :exit, reason ->
      Logger.warning("Could not leave RegionNodes group: #{inspect(reason)}")
      :ok
  end

  @impl true
  def init(region) do
    # A restart after shutdown began must not re-advertise the node
    if SignalHandler.shutdown_in_progress?() == :ok do
      :ok = :syn.join(RegionNodes, region, self(), node: node())
    end

    {:ok, region}
  end

  @impl true
  def handle_call(:leave, _from, region) do
    Logger.info("Leaving RegionNodes group #{inspect(region)}")
    _ = :syn.leave(RegionNodes, region, self())
    {:reply, :ok, region}
  end
end
