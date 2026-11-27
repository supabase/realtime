defmodule Realtime.Readiness do
  @moduledoc """
  Whether this node should be sent new connections, behind `GET /ready`.

  `READINESS_MIN_NODES_PER_REGION` (e.g. `us-east-1=2,eu-west-1=2`) lists the regions a node waits for: it is not
  ready until its cluster has at least that many nodes in each of them, counted from the `RegionNodes` scope. Once
  ready it stays ready, so a region dropping below its minimum later does not take every other node out of rotation.
  Unset, the node is ready as soon as it serves HTTP.

  A node that received SIGTERM is never ready, so a load balancer stops sending it new connections while it drains.

  What a node waits for is logged, not returned: once when it starts waiting, again only when that changes (a node
  joins), and once when it is ready. Readiness probes every few seconds add no log lines of their own.
  """
  require Logger

  alias Realtime.Nodes
  alias Realtime.SignalHandler

  @latch {__MODULE__, :ready}
  @last_logged {__MODULE__, :last_logged}

  @type shortfall :: {region :: String.t(), nodes :: non_neg_integer(), min :: pos_integer()}
  @type reason :: :shutdown_in_progress | {:waiting_for_nodes, [shortfall()]}

  @spec check() :: :ok | {:error, reason()}
  def check do
    with :ok <- SignalHandler.shutdown_in_progress?() do
      :realtime
      |> Application.get_env(:readiness_min_nodes_per_region, [])
      |> check_min_nodes()
    end
  end

  defp check_min_nodes([]), do: :ok

  defp check_min_nodes(minimums) do
    if :persistent_term.get(@latch, false) do
      :ok
    else
      case Enum.flat_map(minimums, &shortfall/1) do
        [] ->
          Logger.info("Readiness: ready, minimum nodes per region reached: #{format(minimums)}")
          :persistent_term.put(@latch, true)
          :persistent_term.erase(@last_logged)
          :ok

        shortfalls ->
          log_if_changed(shortfalls)
          {:error, {:waiting_for_nodes, shortfalls}}
      end
    end
  end

  defp shortfall({region, min}) do
    nodes = region |> Nodes.region_nodes() |> Enum.uniq() |> length()
    if nodes >= min, do: [], else: [{region, nodes, min}]
  end

  # Changes a few times per node lifetime, so :persistent_term's cost on update doesn't matter.
  defp log_if_changed(shortfalls) do
    if :persistent_term.get(@last_logged, nil) != shortfalls do
      :persistent_term.put(@last_logged, shortfalls)
      waiting = Enum.map_join(shortfalls, ", ", fn {region, nodes, min} -> "#{region} #{nodes}/#{min}" end)
      Logger.info("Readiness: waiting for nodes: #{waiting}")
    end
  end

  defp format(minimums), do: Enum.map_join(minimums, ",", fn {region, min} -> "#{region}=#{min}" end)

  @doc false
  # Tests only: forget a reached minimum and what was logged.
  @spec reset() :: :ok
  def reset do
    :persistent_term.erase(@latch)
    :persistent_term.erase(@last_logged)
    :ok
  end
end
