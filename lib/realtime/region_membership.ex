defmodule Realtime.RegionMembership do
  @moduledoc """
  Owns this node's membership of the syn `RegionNodes` group.

  Started last in `Realtime.Application` so this node is only advertised once the
  rest of the tree can serve the work it will be handed.

  Membership carries a `draining` flag rather than being dropped on shutdown: a
  node that is going away must stop being *elected* for new work
  (`Realtime.Nodes.eligible_region_nodes/1`) while peers keep *delivering* to the
  clients still connected to it (`Realtime.Nodes.region_nodes/1`).
  """
  use GenServer
  require Logger

  def start_link(region), do: GenServer.start_link(__MODULE__, region, name: __MODULE__)

  @doc "Marks this node as draining. No-op when the process is not running."
  @spec drain() :: :ok
  def drain do
    case GenServer.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.call(__MODULE__, :drain)
    end
  end

  @impl true
  def init(region) do
    :ok = :syn.join(RegionNodes, region, self(), node: node())
    {:ok, region}
  end

  @impl true
  def handle_call(:drain, _from, region) do
    Logger.info("Draining RegionNodes group #{inspect(region)}")
    :ok = :syn.join(RegionNodes, region, self(), node: node(), draining: true)
    {:reply, :ok, region}
  end
end
