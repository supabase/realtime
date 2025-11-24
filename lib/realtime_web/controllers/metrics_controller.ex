defmodule RealtimeWeb.MetricsController do
  use RealtimeWeb, :controller
  require Logger
  alias Realtime.PromEx
  alias Realtime.GenRpc

  def index(conn, _) do
    timeout = Application.fetch_env!(:realtime, :metrics_rpc_timeout)

    cluster_metrics =
      Node.list()
      |> Task.async_stream(
        fn node ->
          {node, GenRpc.call(node, PromEx, :get_compressed_metrics, [], timeout: timeout)}
        end,
        timeout: :infinity
      )
      |> Enum.reduce([PromEx.get_metrics()], fn {_, {node, response}}, acc ->
        case response do
          {:error, :rpc_error, reason} ->
            Logger.error("Cannot fetch metrics from the node #{inspect(node)} because #{inspect(reason)}")
            acc

          metrics ->
            [uncompress(metrics) | acc]
        end
      end)
      |> Enum.reverse()

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, cluster_metrics)
  end

  defp uncompress(compressed_data) do
    :zlib.uncompress(compressed_data)
  rescue
    error ->
      Logger.error("Failed to decompress metrics data: #{inspect(error)}")
      # Return empty string to not impact the aggregated metrics
      ""
  end
end
