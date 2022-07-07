defmodule RealtimeWeb.MetricsController do
  use RealtimeWeb, :controller
  require Logger
  alias Realtime.PromEx

  def index(conn, _) do
    cluster_metrics =
      Node.list()
      |> Task.async_stream(
        fn node ->
          {node, :rpc.call(node, PromEx, :get_metrics, [], 10_000)}
        end,
        timeout: :infinity
      )
      |> Enum.reduce(PromEx.get_metrics(), fn {_, {node, response}}, acc ->
        case response do
          {:badrpc, reason} ->
            Logger.error(
              "Cannot fetch metrics from the node #{inspect(node)} because #{inspect(reason)}"
            )

            acc

          metrics ->
            acc <> metrics
        end
      end)

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, cluster_metrics)
  end
end
