defmodule RealtimeWeb.MetricsController do
  use RealtimeWeb, :controller
  require Logger
  alias Realtime.PromEx
  alias Realtime.GenRpc

  # We give more memory and time to collect metrics from all nodes as this is a lot of work
  def index(conn, _) do
    {time, metrics} = :timer.tc(fn -> metrics([Node.self() | Node.list()]) end, :millisecond)
    Logger.info("Collected cluster metrics in #{time} milliseconds")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  def region(conn, %{"region" => region}) do
    nodes = Realtime.Nodes.region_nodes(region)
    {time, metrics} = :timer.tc(fn -> metrics(nodes) end, :millisecond)
    Logger.info("Collected metrics for region #{region} in #{time} milliseconds")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, metrics)
  end

  defp metrics(nodes) do
    bump_max_heap_size()
    timeout = Application.fetch_env!(:realtime, :metrics_rpc_timeout)

    nodes
    |> Task.async_stream(
      fn node ->
        {node, GenRpc.call(node, __MODULE__, :get_metrics, [], timeout: timeout)}
      end,
      timeout: :infinity
    )
    |> Enum.reduce([], fn {_, {node, response}}, acc ->
      case response do
        {:error, :rpc_error, reason} ->
          Logger.error("Cannot fetch metrics from the node #{inspect(node)} because #{inspect(reason)}")
          acc

        metrics ->
          [metrics | acc]
      end
    end)
  end

  def get_metrics() do
    bump_max_heap_size()
    PromEx.get_metrics()
  end

  defp bump_max_heap_size() do
    system_max_heap_size = :erlang.system_info(:max_heap_size)[:size]

    # it's 0 when there is no limit
    if is_integer(system_max_heap_size) and system_max_heap_size > 0 do
      Process.flag(:max_heap_size, system_max_heap_size * 3)
    end
  end
end
