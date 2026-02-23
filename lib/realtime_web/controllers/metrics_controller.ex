defmodule RealtimeWeb.MetricsController do
  use RealtimeWeb, :controller
  require Logger
  alias Realtime.PromEx
  alias Realtime.TenantPromEx
  alias Realtime.GenRpc

  def index(conn, _) do
    serve_metrics(conn, [Node.self() | Node.list()], :get_global_metrics, "global cluster")
  end

  def tenant(conn, _) do
    serve_metrics(conn, [Node.self() | Node.list()], :get_tenant_metrics, "tenant cluster")
  end

  def region(conn, %{"region" => region}) do
    serve_metrics(conn, Realtime.Nodes.region_nodes(region), :get_global_metrics, "global region=#{region}")
  end

  def region_tenant(conn, %{"region" => region}) do
    serve_metrics(conn, Realtime.Nodes.region_nodes(region), :get_tenant_metrics, "tenant region=#{region}")
  end

  defp serve_metrics(conn, nodes, metrics_fun, label) do
    conn =
      conn
      |> put_resp_content_type("text/plain")
      |> send_chunked(200)

    {time, conn} = :timer.tc(fn -> collect_metrics(nodes, metrics_fun, conn) end, :millisecond)
    Logger.info("Collected #{label} metrics in #{time} milliseconds")

    conn
  end

  defp collect_metrics(nodes, metrics_fun, conn) do
    bump_max_heap_size()
    timeout = Application.fetch_env!(:realtime, :metrics_rpc_timeout)

    nodes
    |> Task.async_stream(
      fn node ->
        {node, GenRpc.call(node, __MODULE__, metrics_fun, [], timeout: timeout)}
      end,
      timeout: :infinity
    )
    |> Enum.reduce(conn, fn {_, {node, response}}, acc_conn ->
      case response do
        {:error, :rpc_error, reason} ->
          Logger.error("Cannot fetch metrics from the node #{inspect(node)} because #{inspect(reason)}")
          acc_conn

        metrics ->
          {:ok, acc_conn} = chunk(acc_conn, metrics)
          :erlang.garbage_collect()
          acc_conn
      end
    end)
  end

  def get_global_metrics do
    bump_max_heap_size()
    PromEx.get_global_metrics()
  end

  def get_tenant_metrics do
    bump_max_heap_size()
    TenantPromEx.get_metrics()
  end

  @doc deprecated: "Use get_global_metrics/0 instead"
  def get_metrics, do: get_global_metrics()

  defp bump_max_heap_size do
    system_max_heap_size = :erlang.system_info(:max_heap_size)[:size]

    if is_integer(system_max_heap_size) and system_max_heap_size > 0 do
      Process.flag(:max_heap_size, system_max_heap_size * 3)
    end
  end
end
